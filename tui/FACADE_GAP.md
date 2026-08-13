# TUI Facade 缺口记录

本文件记录当前 `TuiFacade` 实现与前端语义契约之间仍存在的差距。已修复的契约保留在对应条目中，避免把历史审查结论误认为当前缺口；前端不会通过访问 backend、transport 或 protocol 内部来绕过 facade。

## 1. `reconnecting` 连接状态缺失（SPP 序号耗尽已实现）

**契约要求**：前端必须能够显示 `TuiConnectionState.reconnecting`，用于 f=27 后 RFCOMM 重建等后端管理的短暂重连，而不自行重连或再次提交 authkey。

**当前状态**：SPP 序号空间耗尽的 fail-closed 处理和 `failureCode` 透传已经实现。稳定错误码为 `rfcomm_rebuild_required`，facade 会记录协议错误日志并在快照中提供 notice；新物理连接成功后清除该错误。`BackendConnectionState` 仍只有 `disconnected / connecting / awaitingAuthKey / authenticating / ready`，没有独立的 `reconnecting`。`TuiFacade._connectionView` 也无法映射出该状态。

**影响页面**：设备/连接页、任务页顶部的连接摘要。

**建议修复方向**：后端在 RFCOMM 重建期间显式暴露 `reconnecting` 状态；facade 直接映射，不合成业务逻辑。

## 2. `successVerifiedByDeviceBusinessEvent`（已修复）

**契约要求**：`TuiActiveTask.successVerifiedByDeviceBusinessEvent` 必须为显式布尔值，100% 确认发送但设备未回业务完成事件时不得冒充成功。

**当前状态**：`InstallTask` 现在显式携带 `successVerifiedByDeviceBusinessEvent`，默认值为 `false`。表盘路径只有在收到并校验当前 `faceId` 的 A9u `installResult`（code 2/3）后置为 `true`；RPK 路径只有在收到匹配包名且 code 为 0 的 V8s 业务结果后置为 `true`。`TuiFacade._taskView` 直接映射该字段，不再从 stage 反推。

**影响页面**：当前任务/传输页、队列终态显示。

**剩余风险**：RPK 业务结果目前按包名关联，协议没有可用的事务 ID 字段；同一会话中迟到的同包名事件仍需真机/协议级验证。表盘完成事件的 faceId 关联已收紧，切换响应仍只做 command/sub 匹配。

## 3. `busyOperations` 粒度与语义不完整

**契约要求**：`TuiSnapshot.busyOperations` 应覆盖初始化、扫描、连接、鉴权、导入、设置、导出、清理等正在执行的动作，前端据此禁用重复提交并显示忙碌状态。

**当前状态**：安装/队列运行时目前复用兼容的 `cleanup` busy 枚举；`import` 仅表示文件导入，不表示安装传输。`settings`、`export` 仍未单独暴露为 busy 枚举，属于剩余缺口。

**影响页面**：所有含动作按钮的页面、底部快捷键栏的禁用提示。

**建议修复方向**：
- 为设置保存和安全日志导出增加 facade 级 busy 状态。
- 后续可新增更细分的 `install`/`queue` 枚举，而不是复用 `cleanup`。

## 4. 安装与文件导入已区分（原缺口已修复）

**契约要求**： busy 操作应能区分文件导入和安装传输，避免用户误判。

**当前状态**：`TuiBusyOperation.import` 仅用于 `QueueFileImporter` 文件导入；安装运行暂时复用 `TuiBusyOperation.cleanup`，因此不再存在 `import` 语义过载。

**影响页面**：队列页、任务页、状态栏。

**建议修复方向**：后续可新增 `TuiBusyOperation.install` 或 `queue`，让安装状态拥有专用枚举；前端 DTO 和 facade 再同步更新。

## 5. `clearCompletedQueue` 全局许可（已修复）

**契约要求**：所有全局动作的许可通过 `TuiSnapshot.allowedActions` 暴露，禁止原因通过 `blockedReasons` 暴露。

**当前状态**：当存在完成项且没有安装/队列忙碌状态时，`clearCompletedQueue` 已由 `_allowedActions()` 暴露；facade 同时保留忙碌门控。条目级 `moveQueueItem` 仍通过队列条目自己的许可集合控制。

**影响页面**：队列页。

**剩余风险**：`blockedReasons` 对部分队列/恢复动作仍较粗粒度，见下一条。

## 6. 恢复动作的门控原因未进入 `blockedReasons`

**契约要求**：`blockedReasons` 应包含 `resumeRecovery` 等动作被禁止的具体原因。

**当前状态**：`_blockedReasons()` 只添加了 `resumeRecovery` 的一条原因；当检查点无效、文件变化或安装运行中时，原因没有按 facade 实际门控逻辑细分。

**影响页面**：恢复区块/弹层。

**建议修复方向**：根据 `_recovery.state`、`_backend.sessionReady` 和运行中状态，为 `resumeRecovery` / `discardRecovery` 提供更准确的 `blockedReasons`。

## 7. 日志脱敏规则依赖 facade 正则，而非后端结构化安全日志

**契约要求**：facade 快照不应含秘密；若发现秘密字段，停止使用并记录安全缺口。日志脱敏应由 facade 结合字段语义完成。

**当前状态**：`TuiFacade._safeMessage` 使用正则 `/(base64|nonce|hmac|session|authkey)\s*[:=：][^ ，。;；]+/` 隐藏敏感字段。这是一种防御性兜底，但依赖文本模式匹配；如果后端日志字段名变化或出现新敏感类型，可能漏脱敏。

**影响页面**：日志/诊断页、导出的安全日志。

**建议修复方向**：后端直接输出结构化安全日志（字段名 + 已脱敏标志），facade 不再依赖正则猜测；当前正则作为第二道防线保留。

---

**说明**：剩余缺口主要是重连状态、busy 粒度、恢复门控原因和结构化日志脱敏；前端不会绕过这些契约。
