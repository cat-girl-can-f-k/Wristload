package com.example.wristload

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

/** Android-only RFCOMM bridge. Protocol framing remains in Dart. */
class MainActivity : FlutterActivity() {
    private companion object {
        const val wristloadRfcommEventsChannel = "wristload/rfcomm/events"
        const val wristloadRfcommChannel = "wristload/rfcomm"
        const val wristloadSecureStoreChannel = "wristload/secure_store"

        const val wristloadSecurePreferences = "wristload_secure"
        const val wristloadAuthKeyAlias = "wristload_authkey"
        const val legacySecurePreferences = "miwearable_secure"
        const val legacyAuthKeyAlias = "miwearable_authkey"
    }

    private val executor = Executors.newSingleThreadExecutor()
    @Volatile private var socket: BluetoothSocket? = null
    @Volatile private var input: InputStream? = null
    @Volatile private var output: OutputStream? = null
    private var eventSink: EventChannel.EventSink? = null
    @Volatile private var connectionGeneration = 0L
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, wristloadRfcommEventsChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) { eventSink = sink }
                override fun onCancel(arguments: Any?) { eventSink = null }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wristloadRfcommChannel)
            .setMethodCallHandler { call, result -> handleRfcomm(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wristloadSecureStoreChannel)
            .setMethodCallHandler { call, result -> handleSecureStore(call, result) }
    }

    /** Keeps the authkey encrypted with a non-exportable Android Keystore key. */
    private fun handleSecureStore(call: MethodCall, result: MethodChannel.Result) {
        try {
            val preferences = getSharedPreferences(wristloadSecurePreferences, MODE_PRIVATE)
            when (call.method) {
                "read" -> result.success(readAuthKey(preferences))
                "write" -> {
                    val value = call.arguments as? String
                        ?: throw IllegalArgumentException("Missing secure value")
                    require(Regex("^[0-9a-fA-F]{32}$").matches(value)) {
                        "Authkey must be 32 hexadecimal characters"
                    }
                    check(preferences.edit()
                        .putString("authkey", encryptAuthKey(value))
                        .commit()) { "Unable to persist secure value" }
                    result.success(null)
                }
                "readFor" -> {
                    val id = call.arguments as? String
                        ?: throw IllegalArgumentException("Missing device id")
                    result.success(preferences.getString(deviceAuthKeyPreference(id), null)?.let {
                        decryptAuthKey(it, wristloadAuthKeyAlias)
                    })
                }
                "writeFor" -> {
                    val args = call.arguments as? Map<*, *>
                        ?: throw IllegalArgumentException("Missing device authkey arguments")
                    val id = args["id"] as? String
                        ?: throw IllegalArgumentException("Missing device id")
                    val value = args["value"] as? String
                        ?: throw IllegalArgumentException("Missing authkey value")
                    require(Regex("^[0-9a-fA-F]{32}$").matches(value)) {
                        "Authkey must be 32 hexadecimal characters"
                    }
                    check(preferences.edit()
                        .putString(deviceAuthKeyPreference(id), encryptAuthKey(value))
                        .commit()) { "Unable to persist device authkey" }
                    result.success(null)
                }
                "deleteFor" -> {
                    val id = call.arguments as? String
                        ?: throw IllegalArgumentException("Missing device id")
                    check(preferences.edit().remove(deviceAuthKeyPreference(id)).commit()) {
                        "Unable to remove device authkey"
                    }
                    result.success(null)
                }
                "delete" -> {
                    val legacyPreferences =
                        getSharedPreferences(legacySecurePreferences, MODE_PRIVATE)
                    check(preferences.edit().remove("authkey").commit() &&
                        legacyPreferences.edit().remove("authkey").commit()) {
                        "Unable to remove secure value"
                    }
                    deleteAuthKeyAliases()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("secure_store", error.message, null)
        }
    }

    private fun deviceAuthKeyPreference(id: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
            .digest(id.toByteArray())
        return "authkey_device_" + digest.joinToString("") { "%02x".format(it) }
    }

    private fun readAuthKey(preferences: android.content.SharedPreferences): String? {
        preferences.getString("authkey", null)?.let { return decryptAuthKey(it, wristloadAuthKeyAlias) }

        val legacyPreferences = getSharedPreferences(legacySecurePreferences, MODE_PRIVATE)
        val legacyValue = legacyPreferences.getString("authkey", null) ?: return null
        val authKey = decryptAuthKey(legacyValue, legacyAuthKeyAlias)
        check(preferences.edit().putString("authkey", encryptAuthKey(authKey)).commit()) {
            "Unable to migrate secure value"
        }
        check(legacyPreferences.edit().remove("authkey").commit()) {
            "Unable to finish secure value migration"
        }
        return authKey
    }

    private fun deleteAuthKeyAliases() {
        val store = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        for (alias in listOf(wristloadAuthKeyAlias, legacyAuthKeyAlias)) {
            if (store.containsAlias(alias)) store.deleteEntry(alias)
        }
    }

    private fun authKey(alias: String = wristloadAuthKeyAlias): SecretKey {
        val store = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build())
        return generator.generateKey()
    }

    private fun encryptAuthKey(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, authKey())
        return Base64.encodeToString(cipher.iv + cipher.doFinal(value.toByteArray()), Base64.NO_WRAP)
    }

    private fun decryptAuthKey(value: String, keyAlias: String = wristloadAuthKeyAlias): String {
        val raw = Base64.decode(value, Base64.NO_WRAP)
        require(raw.size > 12) { "Invalid secure value" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, authKey(keyAlias), GCMParameterSpec(128, raw.copyOfRange(0, 12)))
        val decrypted = String(cipher.doFinal(raw.copyOfRange(12, raw.size)))
        require(Regex("^[0-9a-fA-F]{32}$").matches(decrypted)) {
            "Invalid authkey payload"
        }
        return decrypted
    }

    @Suppress("UNCHECKED_CAST")
    private fun handleRfcomm(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensurePermissions" -> ensureBluetoothPermissions(result)
            "pair" -> {
                val address = call.arguments as String
                executor.execute {
                    try {
                        val adapter = BluetoothAdapter.getDefaultAdapter()
                            ?: throw IllegalStateException("Bluetooth unavailable")
                        ensureBonded(adapter.getRemoteDevice(address))
                        runOnUiThread { result.success(null) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("bluetooth_pair", error.message, null) }
                    }
                }
            }
            "connect" -> {
                val args = call.arguments as Map<String, Any>
                val address = args["address"] as String
                val service = UUID.fromString(args["serviceUuid"] as String)
                executor.execute {
                    var pendingSocket: BluetoothSocket? = null
                    try {
                        val generation = beginConnection()
                        val adapter = BluetoothAdapter.getDefaultAdapter()
                            ?: throw IllegalStateException("Bluetooth unavailable")
                        adapter.cancelDiscovery()
                        val device = adapter.getRemoteDevice(address)
                        ensureBonded(device)
                        val connected = device.createRfcommSocketToServiceRecord(service)
                        pendingSocket = connected
                        connected.connect()
                        if (!installConnectedSocket(generation, connected)) {
                            connected.close()
                            throw CancellationException("RFCOMM connection was superseded")
                        }
                        pendingSocket = null
                        startReader(generation, connected.inputStream)
                        runOnUiThread { result.success(null) }
                    } catch (error: Exception) {
                        try { pendingSocket?.close() } catch (_: Exception) {}
                        runOnUiThread { result.error("rfcomm_connect", error.message, null) }
                    }
                }
            }
            "write" -> {
                val data = call.arguments as ByteArray
                executor.execute {
                    try {
                        val stream = output ?: throw IllegalStateException("RFCOMM not connected")
                        stream.write(data)
                        stream.flush()
                        runOnUiThread { result.success(null) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("rfcomm_write", error.message, null) }
                    }
                }
            }
            "disconnect" -> {
                closeSocket()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Android 12+ separates nearby-device Bluetooth permissions from location. */
    private fun ensureBluetoothPermissions(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(null)
            return
        }
        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                android.Manifest.permission.BLUETOOTH_SCAN,
                android.Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
        }
        if (permissions.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) {
            result.success(null)
            return
        }
        if (permissionResult != null) {
            result.error("permission_pending", "Bluetooth permission request already active", null)
            return
        }
        permissionResult = result
        requestPermissions(permissions, 48021)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 48021) return
        val result = permissionResult ?: return
        permissionResult = null
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
            result.success(null)
        } else {
            result.error("bluetooth_permission_denied", "Bluetooth scan/connect permission denied", null)
        }
    }

    /** Waits for the one system bond flow; never removes an existing bond. */
    private fun ensureBonded(device: BluetoothDevice) {
        if (device.bondState == BluetoothDevice.BOND_BONDED) return
        if (device.bondState == BluetoothDevice.BOND_NONE && !device.createBond()) {
            throw IllegalStateException("Unable to start Bluetooth pairing")
        }
        repeat(150) {
            when (device.bondState) {
                BluetoothDevice.BOND_BONDED -> return
                BluetoothDevice.BOND_NONE -> {
                    if (it >= 25) throw IllegalStateException("Bluetooth pairing was rejected")
                }
            }
            Thread.sleep(200)
        }
        throw IllegalStateException("Bluetooth pairing timed out")
    }

    private fun startReader(generation: Long, stream: InputStream) {
        Thread {
            val buffer = ByteArray(4096)
            try {
                while (isCurrentGeneration(generation)) {
                    val count = stream.read(buffer)
                    if (count <= 0) break
                    val packet = buffer.copyOf(count)
                    runOnUiThread {
                        if (isCurrentGeneration(generation)) eventSink?.success(packet)
                    }
                }
                runOnUiThread {
                    if (isCurrentGeneration(generation)) {
                        eventSink?.error("rfcomm_closed", "RFCOMM closed", null)
                    }
                }
            } catch (error: Exception) {
                runOnUiThread {
                    if (isCurrentGeneration(generation)) {
                        eventSink?.error("rfcomm_read", error.message, null)
                    }
                }
            } finally {
                closeCurrentSocket(generation)
            }
        }.start()
    }

    @Synchronized private fun beginConnection(): Long {
        closeSocketLocked()
        connectionGeneration += 1
        return connectionGeneration
    }

    @Synchronized private fun installConnectedSocket(
        generation: Long,
        connected: BluetoothSocket,
    ): Boolean {
        if (generation != connectionGeneration) return false
        socket = connected
        input = connected.inputStream
        output = connected.outputStream
        return true
    }

    @Synchronized private fun isCurrentGeneration(generation: Long): Boolean =
        generation == connectionGeneration

    @Synchronized private fun closeSocket() {
        connectionGeneration += 1
        closeSocketLocked()
    }

    /** Closes this generation's resources without invalidating its queued EOF. */
    @Synchronized private fun closeCurrentSocket(generation: Long) {
        if (generation != connectionGeneration) return
        closeSocketLocked()
    }

    private fun closeSocketLocked() {
        try { input?.close() } catch (_: Exception) {}
        try { output?.close() } catch (_: Exception) {}
        try { socket?.close() } catch (_: Exception) {}
        input = null
        output = null
        socket = null
    }

    override fun onDestroy() {
        permissionResult?.error("activity_destroyed", "Activity destroyed", null)
        permissionResult = null
        closeSocket()
        executor.shutdownNow()
        super.onDestroy()
    }
}
