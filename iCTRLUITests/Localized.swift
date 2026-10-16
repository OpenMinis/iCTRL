import Foundation

/// Lightweight, dependency-free localization for the on-device notifications and
/// their action buttons. iCTRL ships as a re-signed IPA without a .lproj bundle,
/// so instead of NSLocalizedString we key a small in-code table by the system
/// language and fall back to English. Action titles carry an emoji so Allow/Deny
/// etc. are visually distinguishable at a glance.
///
/// Supported: English, 简体中文, 繁體中文, 日本語, 한국어, Español, Deutsch, Русский.
enum L10n {
    enum Lang { case en, zhHans, zhHant, ja, ko, es, de, ru }

    /// The active language bucket, from the user's preferred languages.
    static let lang: Lang = {
        guard let first = Locale.preferredLanguages.first?.lowercased() else { return .en }
        if first.hasPrefix("zh") {
            if first.contains("hant") || first.contains("tw") || first.contains("hk") || first.contains("mo") {
                return .zhHant
            }
            return .zhHans
        }
        if first.hasPrefix("ja") { return .ja }
        if first.hasPrefix("ko") { return .ko }
        if first.hasPrefix("es") { return .es }
        if first.hasPrefix("de") { return .de }
        if first.hasPrefix("ru") { return .ru }
        return .en
    }()

    /// Look up a key; returns the string for the active language (English fallback).
    static func t(_ key: Key) -> String {
        let row = table[key] ?? [:]
        return row[lang] ?? row[.en] ?? ""
    }

    enum Key {
        case allow, deny, enableRemote, disableRemote, stopServer, copyLogs
        case serverReadyTitle, serverFailedTitle, serverStoppedTitle
        case remoteDisabledTitle, remoteFailedTitle, enableLocalNetworkTitle
        case authRequestTitle
        case localOnlyBody, longPressRemoteOrStop
        case longPressCopyLogs, serverStoppedBody
        case remoteFailedBody, remoteDisabledBody
        case authRequestBody       // %@ = client name
        case authRequestNearbyBody // %@ = client name; the request came over peer-to-peer Wi-Fi
        case authKeyLine           // %@ = key fingerprint the client also prints
        case stopConfirmTitle, stopConfirmBody
        case onDeviceOnlySuffix
        // Reachability marker shown on the status notification (one of three).
        case statusNearby, statusLAN, statusLocal, statusNoLAN
        case nearbyStarting, nearbyNeedsWiFi, nearbyNeedsPermission, nearbyNotReady
        case enableNearby, disableNearby, longPressNearbyOrStop

        // ── Host app UI ──
        //
        // Only English and Chinese are filled in for these: the rest fall back to
        // English, which is the point of having a fallback. Technical strings the
        // user would search for or paste into a bug report (FFI errors, HTTP
        // status, bundle ids) are deliberately NOT here — translating them makes
        // them harder to look up, not easier.
        case runtimeRequirements, developerDiskImage, mountPoint
        case mountWithoutMac, remount
        case ddiReadyFooter
        case serverSectionTitle, statusLabel, addressLabel, checking, running, stopped
        case startServer, stopServerButton, serverLabel, protocolLabel, methodsLabel, capabilitiesLabel
        case serverRunningFooter, mountFirstFooter, startOpensRunnerFooter
        case deviceSection, modelLabel, systemLabel, screenLabel, nameLabel
        case aboutSection, versionLabel, logsLabel, logsFooter
        case alternativeSection, alternativeFooter
        case mountTitle, doneButton, prerequisiteHeader
        case startLocalDevVPN, tunnelUpDetail, vpnInstalledDetail, vpnMissingDetail
        case openVPNAndConnect, getVPNFromAppStore, tunnelDetectedFooter, cannotStartVPNFooter
        case importPairingFile, choosePairingFile, replacePairingFile, removePairingFile
        case pairingHint, pairingImported, pairingReceivedTitle, pairingReceivedBody, pairingRejectedTitle
        case ddiComponentTitle, ddiDownloadHint, ddiDownloaded, downloadImageFiles, ddiSourceFooter
        case mountButton, mountedOK, mountFailed, mountNotPersistentFooter, firstMountNetworkFooter
        case finishStepsFirst, vpnNotConnected, vpnNotInstalled, noPairingFile, imagesNotDownloaded
        case localNetworkDeniedDetail, openSettings, interfacesSeen
        case networkPermissionTitle, networkPermissionBody, networkDataPermission, localNetworkPermission, laterButton
        case wifiRequired, wifiConnected, wifiMissing, wifiFooter, notOnWiFi
        case mountIntro, uploadingImage
        case authorizedClients, runnerLogs, appLogsSection, runnerSection
        case connectRunnerTitle, connectRunnerBody, connectButton, waitingApproval
        case runnerNotRunningHint, keyRejectedHint, pairDeniedHint, retryInSeconds
        case thisApp, revokeButton, revokeOthers, revokeConfirmTitle, revokeConfirmBody
        case revokeOthersConfirm, disconnectThisApp, disconnectConfirmBody
        case noClients, pairedAt, lastActive, clientsFooter
        case liveLabel, pausedLabel, filterPlaceholder, noLogLines, copyButton, runnerLogsCaption, cancelButton
        case viaLocal, viaLAN, viaNearby, viaVPN, viaCellular, viaOther
        case visibilityLabel, visibilityLocal, visibilityLAN, visibilityLANNearby, visibilityNearbyPending, runnerLocalNetworkDenied
    }

    // key → (lang → text). English is the required fallback for every key.
    private static let table: [Key: [Lang: String]] = [
        // ── Action buttons (distinguishing emoji) ──
        .allow: [.en: "✅ Allow", .zhHans: "✅ 允许", .zhHant: "✅ 允許", .ja: "✅ 許可",
                 .ko: "✅ 허용", .es: "✅ Permitir", .de: "✅ Zulassen", .ru: "✅ Разрешить"],
        .deny: [.en: "⛔️ Deny", .zhHans: "⛔️ 拒绝", .zhHant: "⛔️ 拒絕", .ja: "⛔️ 拒否",
                .ko: "⛔️ 거부", .es: "⛔️ Denegar", .de: "⛔️ Ablehnen", .ru: "⛔️ Отклонить"],
        .enableRemote: [.en: "🌐 Enable Remote Access", .zhHans: "🌐 开启远程访问", .zhHant: "🌐 開啟遠端存取", .ja: "🌐 リモートを有効化",
                        .ko: "🌐 원격 접속 켜기", .es: "🌐 Activar acceso remoto", .de: "🌐 Fernzugriff aktivieren", .ru: "🌐 Включить удалённый доступ"],
        .disableRemote: [.en: "🔒 Disable Remote Access", .zhHans: "🔒 关闭远程访问", .zhHant: "🔒 關閉遠端存取", .ja: "🔒 リモートを無効化",
                         .ko: "🔒 원격 접속 끄기", .es: "🔒 Desactivar acceso remoto", .de: "🔒 Fernzugriff deaktivieren", .ru: "🔒 Выключить удалённый доступ"],
        .stopServer: [.en: "🛑 Stop Server", .zhHans: "🛑 停止服务", .zhHant: "🛑 停止服務", .ja: "🛑 サーバー停止",
                      .ko: "🛑 서버 중지", .es: "🛑 Detener servidor", .de: "🛑 Server stoppen", .ru: "🛑 Остановить сервер"],
        .copyLogs: [.en: "📋 Copy Logs", .zhHans: "📋 复制日志", .zhHant: "📋 複製日誌", .ja: "📋 ログをコピー",
                    .ko: "📋 로그 복사", .es: "📋 Copiar registros", .de: "📋 Logs kopieren", .ru: "📋 Копировать логи"],

        // ── Notification titles ──
        .serverReadyTitle: [.en: "🟢 iCTRL Server Ready", .zhHans: "🟢 iCTRL 服务已就绪", .zhHant: "🟢 iCTRL 服務已就緒", .ja: "🟢 iCTRL サーバー準備完了",
                            .ko: "🟢 iCTRL 서버 준비됨", .es: "🟢 Servidor iCTRL listo", .de: "🟢 iCTRL-Server bereit", .ru: "🟢 Сервер iCTRL готов"],
        .serverFailedTitle: [.en: "🔴 iCTRL Server Failed", .zhHans: "🔴 iCTRL 服务启动失败", .zhHant: "🔴 iCTRL 服務啟動失敗", .ja: "🔴 iCTRL サーバー起動失敗",
                             .ko: "🔴 iCTRL 서버 시작 실패", .es: "🔴 Error del servidor iCTRL", .de: "🔴 iCTRL-Server fehlgeschlagen", .ru: "🔴 Сбой сервера iCTRL"],
        .serverStoppedTitle: [.en: "⏹️ iCTRL Server Stopped", .zhHans: "⏹️ iCTRL 服务已停止", .zhHant: "⏹️ iCTRL 服務已停止", .ja: "⏹️ iCTRL サーバー停止",
                              .ko: "⏹️ iCTRL 서버 중지됨", .es: "⏹️ Servidor iCTRL detenido", .de: "⏹️ iCTRL-Server gestoppt", .ru: "⏹️ Сервер iCTRL остановлен"],
        .remoteDisabledTitle: [.en: "🔒 Remote Access Disabled", .zhHans: "🔒 远程访问已关闭", .zhHant: "🔒 遠端存取已關閉", .ja: "🔒 リモートアクセス無効",
                               .ko: "🔒 원격 접속 꺼짐", .es: "🔒 Acceso remoto desactivado", .de: "🔒 Fernzugriff deaktiviert", .ru: "🔒 Удалённый доступ выключен"],
        .remoteFailedTitle: [.en: "🔴 Remote Access Failed", .zhHans: "🔴 远程访问失败", .zhHant: "🔴 遠端存取失敗", .ja: "🔴 リモートアクセス失敗",
                             .ko: "🔴 원격 접속 실패", .es: "🔴 Acceso remoto fallido", .de: "🔴 Fernzugriff fehlgeschlagen", .ru: "🔴 Сбой удалённого доступа"],
        .enableLocalNetworkTitle: [.en: "⚠️ Enable Local Network for iCTRL", .zhHans: "⚠️ 请为 iCTRL 开启本地网络", .zhHant: "⚠️ 請為 iCTRL 開啟區域網路", .ja: "⚠️ iCTRL のローカルネットワークを許可",
                                   .ko: "⚠️ iCTRL 로컬 네트워크 허용", .es: "⚠️ Activa la red local para iCTRL", .de: "⚠️ Lokales Netzwerk für iCTRL aktivieren", .ru: "⚠️ Разрешите локальную сеть для iCTRL"],
        .authRequestTitle: [.en: "🔐 Authorization Request", .zhHans: "🔐 授权请求", .zhHant: "🔐 授權請求", .ja: "🔐 認証リクエスト",
                            .ko: "🔐 인증 요청", .es: "🔐 Solicitud de autorización", .de: "🔐 Autorisierungsanfrage", .ru: "🔐 Запрос авторизации"],

        // ── Bodies / fragments ──
        .localOnlyBody: [.en: "Running on 127.0.0.1:8200 (local only)", .zhHans: "运行于 127.0.0.1:8200(仅本机)", .zhHant: "執行於 127.0.0.1:8200(僅本機)", .ja: "127.0.0.1:8200 で稼働中(ローカルのみ)",
                         .ko: "127.0.0.1:8200 에서 실행 중(로컬 전용)", .es: "En ejecución en 127.0.0.1:8200 (solo local)", .de: "Läuft auf 127.0.0.1:8200 (nur lokal)", .ru: "Работает на 127.0.0.1:8200 (только локально)"],
        .longPressRemoteOrStop: [.en: "Long press for Remote Access or Stop Server", .zhHans: "长按可开启远程访问或停止服务", .zhHant: "長按可開啟遠端存取或停止服務", .ja: "長押しでリモート有効化／サーバー停止",
                                 .ko: "길게 눌러 원격 접속 또는 서버 중지", .es: "Mantén pulsado para acceso remoto o detener servidor", .de: "Lang drücken für Fernzugriff oder Server stoppen", .ru: "Удерживайте для удалённого доступа или остановки сервера"],
        .longPressCopyLogs: [.en: "Long press to Copy Logs", .zhHans: "长按可复制日志", .zhHant: "長按可複製日誌", .ja: "長押しでログをコピー",
                             .ko: "길게 눌러 로그 복사", .es: "Mantén pulsado para copiar registros", .de: "Lang drücken zum Kopieren der Logs", .ru: "Удерживайте, чтобы скопировать логи"],
        .serverStoppedBody: [.en: "The automation server has stopped.", .zhHans: "自动化服务已停止。", .zhHant: "自動化服務已停止。", .ja: "オートメーションサーバーが停止しました。",
                             .ko: "자동화 서버가 중지되었습니다.", .es: "El servidor de automatización se ha detenido.", .de: "Der Automatisierungsserver wurde gestoppt.", .ru: "Сервер автоматизации остановлен."],
        .remoteDisabledBody: [.en: "Now local only at 127.0.0.1:8200", .zhHans: "现在仅本机可访问 127.0.0.1:8200", .zhHant: "現在僅本機可存取 127.0.0.1:8200", .ja: "現在は 127.0.0.1:8200 のローカルのみ",
                              .ko: "이제 127.0.0.1:8200 로컬 전용", .es: "Ahora solo local en 127.0.0.1:8200", .de: "Jetzt nur lokal unter 127.0.0.1:8200", .ru: "Теперь только локально на 127.0.0.1:8200"],
        .remoteFailedBody: [.en: "iCTRL is listening but %@ can't be reached — likely the Local Network permission. Open the iCTRL app once and allow Local Network, then reconnect. (localhost still works.)",
                            .zhHans: "iCTRL 已在监听,但无法访问 %@ —— 可能是本地网络权限未开启。请打开 iCTRL App 允许本地网络后重连。(localhost 仍可用)",
                            .zhHant: "iCTRL 已在監聽,但無法存取 %@ —— 可能是區域網路權限未開啟。請開啟 iCTRL App 允許區域網路後重連。(localhost 仍可用)",
                            .ja: "iCTRL は待受中ですが %@ に到達できません — ローカルネットワーク権限が原因の可能性。iCTRL アプリを開いて許可し、再接続してください。(localhost は利用可)",
                            .ko: "iCTRL 가 수신 중이지만 %@ 에 연결할 수 없습니다 — 로컬 네트워크 권한 문제일 수 있습니다. iCTRL 앱을 열어 로컬 네트워크를 허용한 뒤 다시 연결하세요. (localhost 는 사용 가능)",
                            .es: "iCTRL está escuchando pero no se puede acceder a %@ — probablemente el permiso de Red local. Abre la app iCTRL, permite la Red local y vuelve a conectar. (localhost sigue funcionando)",
                            .de: "iCTRL lauscht, aber %@ ist nicht erreichbar — vermutlich die Berechtigung „Lokales Netzwerk“. Öffne die iCTRL-App, erlaube das lokale Netzwerk und verbinde dich neu. (localhost funktioniert weiterhin)",
                            .ru: "iCTRL слушает, но %@ недоступен — вероятно, нет разрешения на локальную сеть. Откройте приложение iCTRL, разрешите локальную сеть и переподключитесь. (localhost по-прежнему работает)"],
        .stopConfirmTitle: [.en: "Stop iCTRL?", .zhHans: "停止 iCTRL？", .zhHant: "停止 iCTRL？", .ja: "iCTRL を停止しますか？",
                             .ko: "iCTRL을 중지할까요?", .es: "¿Detener iCTRL?", .de: "iCTRL stoppen?", .ru: "Остановить iCTRL?"],
        .stopConfirmBody: [.en: "An app asked to stop the server. Long press to stop it, or ignore this.",
                           .zhHans: "有 App 请求停止服务。长按以停止，或忽略此通知。",
                           .zhHant: "有 App 請求停止服務。長按以停止，或忽略此通知。",
                           .ja: "アプリがサーバーの停止を要求しました。長押しで停止、または無視してください。",
                           .ko: "앱이 서버 중지를 요청했습니다. 길게 눌러 중지하거나 무시하세요.",
                           .es: "Una app pidió detener el servidor. Mantén pulsado para detenerlo o ignóralo.",
                           .de: "Eine App möchte den Server stoppen. Lange drücken zum Stoppen oder ignorieren.",
                           .ru: "Приложение просит остановить сервер. Удерживайте, чтобы остановить, или игнорируйте."],
        .authKeyLine: [.en: "Key %@ — allow only if your computer shows the same",
                       .zhHans: "密钥 %@ — 与电脑上显示的一致才允许",
                       .zhHant: "金鑰 %@ — 與電腦上顯示的一致才允許",
                       .ja: "キー %@ — コンピュータの表示と一致する場合のみ許可",
                       .ko: "키 %@ — 컴퓨터에 표시된 것과 같을 때만 허용",
                       .es: "Clave %@ — permite solo si tu ordenador muestra la misma",
                       .de: "Schlüssel %@ — nur erlauben, wenn dein Computer denselben zeigt",
                       .ru: "Ключ %@ — разрешайте, только если компьютер показывает такой же"],
        .authRequestBody: [.en: "\"%@\" wants to control this device.\nLong press to Allow or Deny",
                           .zhHans: "“%@” 请求控制此设备。\n长按以允许或拒绝",
                           .zhHant: "「%@」請求控制此裝置。\n長按以允許或拒絕",
                           .ja: "「%@」がこのデバイスの操作を要求しています。\n長押しで許可または拒否",
                           .ko: "\"%@\"이(가) 이 기기의 제어를 요청합니다.\n길게 눌러 허용 또는 거부",
                           .es: "\"%@\" quiere controlar este dispositivo.\nMantén pulsado para permitir o denegar",
                           .de: "„%@“ möchte dieses Gerät steuern.\nLang drücken zum Zulassen oder Ablehnen",
                           .ru: "«%@» хочет управлять этим устройством.\nУдерживайте, чтобы разрешить или отклонить"],
        .authRequestNearbyBody: [.en: "\"%@\" (nearby device) wants to control this device.\nLong press to Allow or Deny",
                                 .zhHans: "“%@”（附近设备）请求控制此设备。\n长按以允许或拒绝",
                                 .zhHant: "「%@」（附近裝置）請求控制此裝置。\n長按以允許或拒絕",
                                 .ja: "「%@」（近くのデバイス）がこのデバイスの操作を要求しています。\n長押しで許可または拒否",
                                 .ko: "\"%@\"(근처 기기)이(가) 이 기기의 제어를 요청합니다.\n길게 눌러 허용 또는 거부",
                                 .es: "\"%@\" (dispositivo cercano) quiere controlar este dispositivo.\nMantén pulsado para permitir o denegar",
                                 .de: "„%@“ (Gerät in der Nähe) möchte dieses Gerät steuern.\nLang drücken zum Zulassen oder Ablehnen",
                                 .ru: "«%@» (устройство поблизости) хочет управлять этим устройством.\nУдерживайте, чтобы разрешить или отклонить"],
        .statusNearby: [.en: "📡 Nearby discoverable", .zhHans: "📡 附近可发现", .zhHant: "📡 附近可發現", .ja: "📡 近くから検出可能",
                        .ko: "📡 근처에서 검색 가능", .es: "📡 Visible cerca", .de: "📡 In der Nähe sichtbar", .ru: "📡 Виден поблизости"],
        .statusLAN: [.en: "🌐 LAN reachable", .zhHans: "🌐 局域网可访问", .zhHant: "🌐 區域網路可存取", .ja: "🌐 LAN から接続可能",
                     .ko: "🌐 LAN 접속 가능", .es: "🌐 Accesible en la LAN", .de: "🌐 Im LAN erreichbar", .ru: "🌐 Доступен в LAN"],
        .statusLocal: [.en: "🔒 This device only", .zhHans: "🔒 仅本机", .zhHant: "🔒 僅本機", .ja: "🔒 この端末のみ",
                       .ko: "🔒 이 기기만", .es: "🔒 Solo este dispositivo", .de: "🔒 Nur dieses Gerät", .ru: "🔒 Только это устройство"],
        .statusNoLAN: [.en: "🌐 No LAN · connect to Wi-Fi", .zhHans: "🌐 无局域网 · 需连接 Wi-Fi", .zhHant: "🌐 無區域網路 · 需連接 Wi-Fi", .ja: "🌐 LAN なし · Wi-Fi に接続",
                       .ko: "🌐 LAN 없음 · Wi-Fi 연결 필요", .es: "🌐 Sin LAN · conéctate a Wi-Fi", .de: "🌐 Kein LAN · mit WLAN verbinden", .ru: "🌐 Нет LAN · подключитесь к Wi-Fi"],
        .nearbyStarting: [.en: "📡 Nearby starting…", .zhHans: "📡 近场启动中…", .zhHant: "📡 近場啟動中…", .ja: "📡 近距離検出を開始中…",
                          .ko: "📡 근거리 검색 시작 중…", .es: "📡 Iniciando detección cercana…", .de: "📡 Nahbereich startet…", .ru: "📡 Запуск обнаружения…"],
        .nearbyNeedsWiFi: [.en: "📡 Nearby not ready · turn on Wi-Fi", .zhHans: "📡 近场未就绪 · 需打开 Wi-Fi", .zhHant: "📡 近場未就緒 · 需開啟 Wi-Fi", .ja: "📡 近距離検出は待機中 · Wi-Fi をオン",
                           .ko: "📡 근거리 검색 대기 · Wi-Fi 켜기 필요", .es: "📡 Cercanía no lista · activa el Wi-Fi", .de: "📡 Nahbereich nicht bereit · WLAN einschalten", .ru: "📡 Поблизости не готово · включите Wi-Fi"],
        .nearbyNeedsPermission: [.en: "📡 Nearby not ready · allow Local Network", .zhHans: "📡 近场未就绪 · 需允许本地网络", .zhHant: "📡 近場未就緒 · 需允許區域網路", .ja: "📡 近距離検出は待機中 · ローカルネットワークを許可",
                                 .ko: "📡 근거리 검색 대기 · 로컬 네트워크 허용 필요", .es: "📡 Cercanía no lista · permite Red local", .de: "📡 Nahbereich nicht bereit · Lokales Netzwerk erlauben", .ru: "📡 Поблизости не готово · разрешите локальную сеть"],
        .nearbyNotReady: [.en: "📡 Nearby not ready · retrying", .zhHans: "📡 近场未就绪 · 正在重试", .zhHant: "📡 近場未就緒 · 正在重試", .ja: "📡 近距離検出は待機中 · 再試行中",
                          .ko: "📡 근거리 검색 대기 · 재시도 중", .es: "📡 Cercanía no lista · reintentando", .de: "📡 Nahbereich nicht bereit · neuer Versuch", .ru: "📡 Поблизости не готово · повтор"],
        .enableNearby: [.en: "📡 Enable Nearby Discovery", .zhHans: "📡 开启近场发现", .zhHant: "📡 開啟近場探索", .ja: "📡 近距離検出を有効化",
                        .ko: "📡 근거리 검색 켜기", .es: "📡 Activar detección cercana", .de: "📡 Nahbereichserkennung ein", .ru: "📡 Включить обнаружение поблизости"],
        .disableNearby: [.en: "📴 Disable Nearby Discovery", .zhHans: "📴 关闭近场发现", .zhHant: "📴 關閉近場探索", .ja: "📴 近距離検出を無効化",
                         .ko: "📴 근거리 검색 끄기", .es: "📴 Desactivar detección cercana", .de: "📴 Nahbereichserkennung aus", .ru: "📴 Выключить обнаружение поблизости"],
        .longPressNearbyOrStop: [.en: "Long press for Nearby Discovery, Remote Access or Stop Server",
                                 .zhHans: "长按可设置近场发现、远程访问或停止服务", .zhHant: "長按可設定近場探索、遠端存取或停止服務",
                                 .ja: "長押しで近距離検出・リモート・サーバー停止", .ko: "길게 눌러 근거리 검색, 원격 접속 또는 서버 중지",
                                 .es: "Mantén pulsado para detección cercana, acceso remoto o detener servidor",
                                 .de: "Lang drücken für Nahbereich, Fernzugriff oder Server stoppen",
                                 .ru: "Удерживайте для обнаружения поблизости, удалённого доступа или остановки"],
        .onDeviceOnlySuffix: [.en: "reachable on-device only; connect over Wi-Fi for LAN access",
                              .zhHans: "仅本机可访问;请连接 Wi-Fi 以支持局域网访问",
                              .zhHant: "僅本機可存取;請連接 Wi-Fi 以支援區域網路存取",
                              .ja: "端末上のみ到達可能;LAN 利用には Wi-Fi 接続が必要",
                              .ko: "기기에서만 접근 가능; LAN 접속은 Wi-Fi 연결 필요",
                              .es: "accesible solo en el dispositivo; conéctate por Wi-Fi para acceso LAN",
                              .de: "nur auf dem Gerät erreichbar; für LAN-Zugriff mit WLAN verbinden",
                              .ru: "доступно только на устройстве; для доступа по LAN подключитесь к Wi-Fi"],

        // ── Host app UI (English base, Chinese translations) ──
        .runtimeRequirements: [.en: "Runtime Requirements", .zhHans: "运行环境要求", .zhHant: "執行環境需求"],
        .developerDiskImage: [.en: "Developer Disk Image", .zhHans: "开发者磁盘镜像", .zhHant: "開發者磁碟映像"],
        .mountPoint: [.en: "Mount point", .zhHans: "挂载位置", .zhHant: "掛載位置"],
        .mountWithoutMac: [.en: "Start local mount…", .zhHans: "开始本地挂载…", .zhHant: "開始本地掛載…"],
        .remount: [.en: "Re-mount…", .zhHans: "重新挂载…", .zhHant: "重新掛載…"],
        .ddiReadyFooter: [.en: "The automation runner can launch on this device. The image is dropped by a reboot — re-mount if the runner stops starting.",
                          .zhHans: "自动化 runner 可以在这台设备上启动。镜像会在重启后丢失——如果 runner 起不来，重新挂载即可。",
                          .zhHant: "自動化 runner 可以在這台裝置上啟動。映像會在重新開機後遺失——如果 runner 起不來，重新掛載即可。"],

        .serverSectionTitle: [.en: "iCTRL Server (Local)", .zhHans: "iCTRL 服务（本机）", .zhHant: "iCTRL 服務（本機）"],
        .statusLabel: [.en: "Status", .zhHans: "状态", .zhHant: "狀態"],
        .addressLabel: [.en: "Address", .zhHans: "地址", .zhHant: "位址"],
        .checking: [.en: "Checking…", .zhHans: "检测中…", .zhHant: "檢測中…"],
        .running: [.en: "Running", .zhHans: "运行中", .zhHant: "執行中"],
        .stopped: [.en: "Stopped", .zhHans: "已停止", .zhHant: "已停止"],
        .startServer: [.en: "Start Server", .zhHans: "启动服务", .zhHant: "啟動服務"],
        .stopServerButton: [.en: "Stop Server", .zhHans: "停止服务", .zhHant: "停止服務"],
        .serverLabel: [.en: "Server", .zhHans: "服务版本", .zhHant: "服務版本"],
        .protocolLabel: [.en: "Protocol", .zhHans: "协议", .zhHant: "協定"],
        .methodsLabel: [.en: "Methods", .zhHans: "方法数", .zhHant: "方法數"],
        .capabilitiesLabel: [.en: "Capabilities", .zhHans: "能力", .zhHant: "能力"],
        .serverRunningFooter: [.en: "Automation clients connect here; every request is encrypted.",
                               .zhHans: "自动化客户端连接到这里；每个请求都是加密的。",
                               .zhHant: "自動化用戶端連線到這裡；每個請求都是加密的。"],
        .mountFirstFooter: [.en: "Mount the Developer Disk Image first — without it the runner can't launch.",
                            .zhHans: "请先挂载开发者磁盘镜像——没有它 runner 无法启动。",
                            .zhHant: "請先掛載開發者磁碟映像——沒有它 runner 無法啟動。"],
        .startOpensRunnerFooter: [.en: "The server runs inside the automation runner. Starting it opens that app.",
                                  .zhHans: "服务运行在自动化 runner 里。启动会打开那个 App。",
                                  .zhHant: "服務執行在自動化 runner 裡。啟動會開啟那個 App。"],

        .deviceSection: [.en: "Device", .zhHans: "设备", .zhHant: "裝置"],
        .modelLabel: [.en: "Model", .zhHans: "型号", .zhHant: "型號"],
        .systemLabel: [.en: "System", .zhHans: "系统", .zhHant: "系統"],
        .screenLabel: [.en: "Screen", .zhHans: "屏幕", .zhHant: "螢幕"],
        .nameLabel: [.en: "Name", .zhHans: "名称", .zhHant: "名稱"],

        .aboutSection: [.en: "About", .zhHans: "关于", .zhHant: "關於"],
        .versionLabel: [.en: "Version", .zhHans: "版本", .zhHant: "版本"],
        .logsLabel: [.en: "Logs", .zhHans: "日志", .zhHant: "日誌"],
        .logsFooter: [.en: "One log per run, kept for the last 20. Tap to read or share one.",
                      .zhHans: "每次运行一份日志，保留最近 20 份。点击可查看或分享。",
                      .zhHant: "每次執行一份日誌，保留最近 20 份。點擊可檢視或分享。"],

        .alternativeSection: [.en: "Alternative", .zhHans: "备选方案", .zhHant: "備選方案"],
        .alternativeFooter: [.en: "The Developer Disk Image doesn't survive a reboot, so mounting has to be repeated after each restart — by either route.",
                             .zhHans: "开发者磁盘镜像重启后会丢失，所以每次重启都要重新挂载——两种方式都一样。",
                             .zhHant: "開發者磁碟映像重新開機後會遺失，所以每次重啟都要重新掛載——兩種方式都一樣。"],

        .mountTitle: [.en: "Mount DDI", .zhHans: "挂载 DDI", .zhHant: "掛載 DDI"],
        .doneButton: [.en: "Done", .zhHans: "完成", .zhHant: "完成"],
        .prerequisiteHeader: [.en: "Prerequisite", .zhHans: "前置条件", .zhHant: "前置條件"],
        .startLocalDevVPN: [.en: "Start LocalDevVPN", .zhHans: "启动 LocalDevVPN", .zhHant: "啟動 LocalDevVPN"],
        .tunnelUpDetail: [.en: "Tunnel is up — this device's debug service is reachable.",
                          .zhHans: "隧道已连接——本机调试服务可达。",
                          .zhHant: "通道已連線——本機除錯服務可達。"],
        .vpnInstalledDetail: [.en: "Installed. Connect it so this device's debug service becomes reachable.",
                              .zhHans: "已安装。连接后本机调试服务才可达。",
                              .zhHant: "已安裝。連線後本機除錯服務才可達。"],
        .vpnMissingDetail: [.en: "Not installed. It makes this device's debug service reachable — iCTRL then talks to it the same way Xcode on a Mac would.",
                            .zhHans: "未安装。它让本机的调试服务变得可达——iCTRL 随后以 Mac 上 Xcode 的同样方式与之通信。",
                            .zhHant: "未安裝。它讓本機的除錯服務變得可達——iCTRL 隨後以 Mac 上 Xcode 的同樣方式與之通訊。"],
        .openVPNAndConnect: [.en: "Open LocalDevVPN & connect", .zhHans: "打开 LocalDevVPN 并连接", .zhHant: "開啟 LocalDevVPN 並連線"],
        .getVPNFromAppStore: [.en: "Get LocalDevVPN on the App Store", .zhHans: "在 App Store 获取 LocalDevVPN", .zhHant: "在 App Store 取得 LocalDevVPN"],
        .tunnelDetectedFooter: [.en: "Detected by connecting to this device's debug service through the tunnel.",
                                .zhHans: "依据能否经隧道连上本机调试服务来判断。",
                                .zhHant: "依據能否經通道連上本機除錯服務來判斷。"],
        .cannotStartVPNFooter: [.en: "iCTRL can't connect the VPN for you — tapping above opens it to do that. If mounting still fails to connect, check it there first.",
                                .zhHans: "iCTRL 无法替你连接 VPN——点击上面会打开它去连接。如果挂载仍然连不上，请先去那里检查。",
                                .zhHant: "iCTRL 無法替你連線 VPN——點擊上面會開啟它去連線。如果掛載仍然連不上，請先去那裡檢查。"],

        .importPairingFile: [.en: "Import a pairing file", .zhHans: "导入配对文件", .zhHant: "匯入配對檔案"],
        .choosePairingFile: [.en: "Choose pairing file…", .zhHans: "选择配对文件…", .zhHant: "選擇配對檔案…"],
        .replacePairingFile: [.en: "Replace pairing file…", .zhHans: "更换配对文件…", .zhHant: "更換配對檔案…"],
        .removePairingFile: [.en: "Remove pairing file", .zhHans: "删除配对文件", .zhHant: "刪除配對檔案"],
        .pairingHint: [.en: "A RemotePairing file is needed. StikDebug's pairingFile.plist works as is; iLoader on this device, or idevice_pair on a computer (choose Remote pairing), can also create one. Send it here via AirDrop, Files or iCloud, or share it to iCTRL from the app that has it.",
                       .zhHans: "需要 RemotePairing 格式的配对文件。StikDebug 的 pairingFile.plist 可直接使用；也可以用本机的 iLoader，或在电脑上用 idevice_pair（选择 Remote pairing）生成。通过隔空投送、文件、iCloud 传过来，或在文件所在的 App 里“分享”到 iCTRL。",
                       .zhHant: "需要 RemotePairing 格式的配對檔案。StikDebug 的 pairingFile.plist 可直接使用；也可以用本機的 iLoader，或在電腦上用 idevice_pair（選擇 Remote pairing）產生。透過 AirDrop、檔案、iCloud 傳過來，或在檔案所在的 App 裡「分享」到 iCTRL。"],
        .pairingImported: [.en: "Imported", .zhHans: "已导入", .zhHant: "已匯入"],
        .pairingReceivedTitle: [.en: "Pairing File Received", .zhHans: "已接收配对文件", .zhHant: "已接收配對檔案"],
        .pairingReceivedBody: [.en: "“%@” has been stored. You can mount the Developer Disk Image now.",
                               .zhHans: "已保存“%@”，现在可以挂载开发者磁盘镜像。",
                               .zhHant: "已儲存「%@」，現在可以掛載開發者磁碟映像。"],
        .pairingRejectedTitle: [.en: "Not a Usable Pairing File", .zhHans: "不是可用的配对文件", .zhHant: "不是可用的配對檔案"],

        .ddiComponentTitle: [.en: "Developer Disk Image", .zhHans: "开发者磁盘镜像", .zhHant: "開發者磁碟映像"],
        .ddiDownloadHint: [.en: "About 100 MB up to iOS 26.3, about 17 MB from iOS 26.4. Downloaded once and reused — only the mount has to be repeated after a reboot.",
                           .zhHans: "iOS 26.3 及以下约 100 MB，iOS 26.4 起约 17 MB。只需下载一次并重复使用——重启后只需重新挂载。",
                           .zhHant: "iOS 26.3 及以下約 100 MB，iOS 26.4 起約 17 MB。只需下載一次並重複使用——重新開機後只需重新掛載。"],
        .ddiDownloaded: [.en: "Downloaded", .zhHans: "已下载", .zhHant: "已下載"],
        .downloadImageFiles: [.en: "Download image files", .zhHans: "下载镜像文件", .zhHant: "下載映像檔案"],
        .ddiSourceFooter: [.en: "Fetched from the DeveloperDiskImage mirror maintained by the pymobiledevice3 author. Apple doesn't publish these for direct download; the same files ship inside Xcode.",
                           .zhHans: "取自 pymobiledevice3 作者维护的 DeveloperDiskImage 镜像源。苹果不提供直接下载；相同文件随 Xcode 一起分发。",
                           .zhHant: "取自 pymobiledevice3 作者維護的 DeveloperDiskImage 鏡像源。蘋果不提供直接下載；相同檔案隨 Xcode 一起分發。"],

        .mountButton: [.en: "Mount Developer Disk Image", .zhHans: "挂载开发者磁盘镜像", .zhHant: "掛載開發者磁碟映像"],
        .mountedOK: [.en: "Mounted — the automation runner can launch now", .zhHans: "已挂载——自动化 runner 现在可以启动了", .zhHant: "已掛載——自動化 runner 現在可以啟動了"],
        .mountFailed: [.en: "Mount failed", .zhHans: "挂载失败", .zhHant: "掛載失敗"],
        .mountNotPersistentFooter: [.en: "The image is not persistent — after a reboot, run this again. The pairing file and downloaded image are kept, so it's one tap.",
                                    .zhHans: "镜像不会持久保留——重启后需要再来一次。配对文件和已下载的镜像会保留，所以只需点一下。",
                                    .zhHant: "映像不會持久保留——重新開機後需要再來一次。配對檔案和已下載的映像會保留，所以只需點一下。"],
        .firstMountNetworkFooter: [.en: "The first mount asks Apple's signing service for a ticket unique to this device, so it needs internet access.",
                                   .zhHans: "首次挂载会向苹果签名服务申请本机专属的票据，因此需要联网。",
                                   .zhHant: "首次掛載會向蘋果簽名服務申請本機專屬的票據，因此需要連網。"],

        .finishStepsFirst: [.en: "Finish the steps above first", .zhHans: "请先完成上面的步骤", .zhHant: "請先完成上面的步驟"],
        .vpnNotConnected: [.en: "LocalDevVPN isn't connected", .zhHans: "LocalDevVPN 未连接", .zhHant: "LocalDevVPN 未連線"],
        .vpnNotInstalled: [.en: "LocalDevVPN isn't installed", .zhHans: "LocalDevVPN 未安装", .zhHant: "LocalDevVPN 未安裝"],
        .noPairingFile: [.en: "no pairing file imported", .zhHans: "尚未导入配对文件", .zhHant: "尚未匯入配對檔案"],
        .imagesNotDownloaded: [.en: "the image files aren't downloaded", .zhHans: "镜像文件尚未下载", .zhHant: "映像檔案尚未下載"],
        .wifiRequired: [.en: "Connect to Wi-Fi", .zhHans: "连接 Wi-Fi", .zhHant: "連線 Wi-Fi"],
        .wifiConnected: [.en: "Connected. Any network will do.", .zhHans: "已连接。任意 Wi-Fi 均可。", .zhHant: "已連線。任意 Wi-Fi 均可。"],
        .wifiMissing: [.en: "Not on Wi-Fi. Mounting needs it — cellular alone won't do.",
                       .zhHans: "当前不在 Wi-Fi 下。挂载需要 Wi-Fi——仅蜂窝网络不行。",
                       .zhHant: "目前不在 Wi-Fi 下。掛載需要 Wi-Fi——僅行動網路不行。"],
        .wifiFooter: [.en: "Any Wi-Fi network works. The tunnel runs over the local interface, which cellular doesn't provide.",
                      .zhHans: "任意 Wi-Fi 都可以。隧道走本地网络接口，蜂窝网络不提供这个。",
                      .zhHant: "任意 Wi-Fi 都可以。通道走本機網路介面，行動網路不提供這個。"],
        .notOnWiFi: [.en: "not connected to Wi-Fi", .zhHans: "未连接 Wi-Fi", .zhHant: "未連線 Wi-Fi"],
        .uploadingImage: [.en: "Uploading image…", .zhHans: "正在上传镜像…", .zhHant: "正在上傳映像…"],
        .mountIntro: [.en: "Mount the Developer Disk Image locally, on this device. iOS needs it before the automation runner can launch, and it does not survive a reboot.",
                      .zhHans: "在本机直接挂载开发者磁盘镜像。iOS 要求先有它，自动化 runner 才能启动；且它在重启后会丢失。",
                      .zhHant: "在本機直接掛載開發者磁碟映像。iOS 要求先有它，自動化 runner 才能啟動；且它在重新開機後會遺失。"],
        .localNetworkDeniedDetail: [.en: "The tunnel is blocked: Local Network access is off for iCTRL. Turn it on in Settings, then come back.",
                                    .zhHans: "隧道被拦截：iCTRL 的“本地网络”权限已关闭。请在设置中打开后再回来。",
                                    .zhHant: "通道被攔截：iCTRL 的「區域網路」權限已關閉。請在設定中開啟後再回來。"],
        .openSettings: [.en: "Open Settings", .zhHans: "打开设置", .zhHant: "開啟設定"],
        .interfacesSeen: [.en: "Addresses on this device:", .zhHans: "本机地址：", .zhHant: "本機位址："],
        .networkPermissionTitle: [.en: "Network access is off", .zhHans: "网络权限未开启", .zhHant: "網路權限未開啟"],
        .networkPermissionBody: [.en: "iCTRL can't work without: %@. Turn it on in Settings → iCTRL.",
                                 .zhHans: "iCTRL 需要以下权限才能工作：%@。请在 设置 → iCTRL 中打开。",
                                 .zhHant: "iCTRL 需要以下權限才能運作：%@。請在 設定 → iCTRL 中開啟。"],
        .networkDataPermission: [.en: "Wireless Data", .zhHans: "无线数据", .zhHant: "無線資料"],
        .localNetworkPermission: [.en: "Local Network", .zhHans: "本地网络", .zhHant: "區域網路"],
        .laterButton: [.en: "Later", .zhHans: "稍后", .zhHant: "稍後"],
        .authorizedClients: [.en: "Authorized Clients", .zhHans: "已授权客户端", .zhHant: "已授權用戶端"],
        .runnerLogs: [.en: "Runner Logs", .zhHans: "Runner 日志", .zhHant: "Runner 日誌"],
        .appLogsSection: [.en: "This App", .zhHans: "本 App", .zhHant: "本 App"],
        .runnerSection: [.en: "Runner", .zhHans: "Runner", .zhHant: "Runner"],
        .connectRunnerTitle: [.en: "Connect to the Runner", .zhHans: "连接 Runner", .zhHant: "連接 Runner"],
        .connectRunnerBody: [.en: "Managing clients and reading the runner's log need its approval once. Tap Connect, then long-press the iCTRL notification and choose Allow.",
                             .zhHans: "管理客户端和查看 Runner 日志需要 Runner 授权一次。点击“连接”，然后长按 iCTRL 通知并选择“允许”。",
                             .zhHant: "管理用戶端和查看 Runner 日誌需要 Runner 授權一次。點擊「連接」，然後長按 iCTRL 通知並選擇「允許」。"],
        .connectButton: [.en: "Connect", .zhHans: "连接", .zhHant: "連接"],
        .waitingApproval: [.en: "Waiting for Allow in the iCTRL notification…", .zhHans: "等待在 iCTRL 通知中允许…", .zhHant: "等待在 iCTRL 通知中允許…"],
        .runnerNotRunningHint: [.en: "The runner is not running. Start the server first.", .zhHans: "Runner 未运行，请先启动服务。", .zhHant: "Runner 未運行，請先啟動服務。"],
        .keyRejectedHint: [.en: "The runner no longer accepts this app (revoked or expired). Connect again.",
                           .zhHans: "Runner 已不再接受本 App（已吊销或过期），请重新连接。",
                           .zhHant: "Runner 已不再接受本 App（已撤銷或過期），請重新連接。"],
        .pairDeniedHint: [.en: "Not allowed, or no answer within 60 seconds.", .zhHans: "未被允许，或 60 秒内未响应。", .zhHant: "未被允許，或 60 秒內未回應。"],
        .retryInSeconds: [.en: "Try again in %d s.", .zhHans: "请 %d 秒后重试。", .zhHant: "請 %d 秒後重試。"],
        .thisApp: [.en: "This app", .zhHans: "本 App", .zhHant: "本 App"],
        .revokeButton: [.en: "Revoke", .zhHans: "吊销", .zhHant: "撤銷"],
        .revokeOthers: [.en: "Revoke All Others", .zhHans: "吊销其他全部", .zhHant: "撤銷其他全部"],
        .revokeConfirmTitle: [.en: "Revoke “%@”?", .zhHans: "吊销“%@”？", .zhHant: "撤銷「%@」？"],
        .revokeConfirmBody: [.en: "Its key stops working at once. To come back it must pair again, approved on this device.",
                             .zhHans: "其密钥立即失效。如需再次使用，必须重新配对并在本机允许。",
                             .zhHant: "其金鑰立即失效。如需再次使用，必須重新配對並在本機允許。"],
        .revokeOthersConfirm: [.en: "Revoke %d clients?", .zhHans: "吊销 %d 个客户端？", .zhHant: "撤銷 %d 個用戶端？"],
        .disconnectThisApp: [.en: "Disconnect This App", .zhHans: "断开本 App", .zhHant: "中斷本 App"],
        .disconnectConfirmBody: [.en: "This app's key is revoked. Viewing clients and logs again needs a new approval.",
                                 .zhHans: "本 App 的密钥将被吊销，再次查看客户端和日志需要重新允许。",
                                 .zhHant: "本 App 的金鑰將被撤銷，再次查看用戶端和日誌需要重新允許。"],
        .noClients: [.en: "No authorized clients.", .zhHans: "没有已授权的客户端。", .zhHant: "沒有已授權的用戶端。"],
        .pairedAt: [.en: "Paired %@", .zhHans: "授权于 %@", .zhHant: "授權於 %@"],
        .lastActive: [.en: "active %@", .zhHans: "最近活动 %@", .zhHant: "最近活動 %@"],
        .clientsFooter: [.en: "Computers, agents and browsers holding a key to this runner. Revoking takes effect immediately.",
                         .zhHans: "持有本 Runner 密钥的电脑、Agent 和浏览器。吊销立即生效。",
                         .zhHant: "持有本 Runner 金鑰的電腦、Agent 和瀏覽器。撤銷立即生效。"],
        .liveLabel: [.en: "Live", .zhHans: "实时", .zhHant: "即時"],
        .pausedLabel: [.en: "Paused", .zhHans: "已暂停", .zhHant: "已暫停"],
        .filterPlaceholder: [.en: "Filter", .zhHans: "筛选", .zhHant: "篩選"],
        .noLogLines: [.en: "No log lines.", .zhHans: "没有日志。", .zhHant: "沒有日誌。"],
        .copyButton: [.en: "Copy", .zhHans: "复制", .zhHant: "拷貝"],
        .runnerLogsCaption: [.en: "The runner's most recent 500 log lines, refreshed every 2 seconds while this screen is open.",
                            .zhHans: "Runner 最近 500 行日志，停留在本页时每 2 秒刷新一次。",
                            .zhHant: "Runner 最近 500 行日誌，停留在本頁時每 2 秒重新整理一次。"],
        .cancelButton: [.en: "Cancel", .zhHans: "取消", .zhHant: "取消"],
        .viaLocal: [.en: "This device / USB", .zhHans: "本机 / USB", .zhHant: "本機 / USB"],
        .viaLAN: [.en: "LAN", .zhHans: "局域网", .zhHant: "區域網路"],
        .viaNearby: [.en: "Nearby (AWDL)", .zhHans: "近场 (AWDL)", .zhHant: "近場 (AWDL)"],
        .viaVPN: [.en: "VPN", .zhHans: "VPN", .zhHant: "VPN"],
        .viaCellular: [.en: "Cellular", .zhHans: "蜂窝网络", .zhHant: "行動網路"],
        .viaOther: [.en: "Other", .zhHans: "其他", .zhHant: "其他"],
        .visibilityLabel: [.en: "Visibility", .zhHans: "可见性", .zhHant: "可見性"],
        .visibilityNearbyPending: [.en: "🟡 LAN · nearby not ready", .zhHans: "🟡 局域网 · 近场未就绪", .zhHant: "🟡 區域網路 · 近場未就緒"],
        .runnerLocalNetworkDenied: [.en: "⚠️ The runner has no Local Network access, so nearby discovery cannot work. Allow it in Settings › Privacy & Security › Local Network › iCTRLUITests-Runner.",
                                    .zhHans: "⚠️ Runner 没有本地网络权限，近场发现无法使用。请在 设置 › 隐私与安全 › 本地网络 中打开 iCTRLUITests-Runner。",
                                    .zhHant: "⚠️ Runner 沒有本地網路權限，近場探索無法使用。請在 設定 › 隱私權與安全性 › 本地網路 中開啟 iCTRLUITests-Runner。"],
        .visibilityLocal: [.en: "🟢 This device only · safe", .zhHans: "🟢 仅本机 · 安全", .zhHant: "🟢 僅本機 · 安全"],
        .visibilityLAN: [.en: "🟡 LAN", .zhHans: "🟡 局域网", .zhHant: "🟡 區域網路"],
        .visibilityLANNearby: [.en: "🟡 LAN + Nearby (AWDL)", .zhHans: "🟡 局域网 + 近场 (AWDL)", .zhHant: "🟡 區域網路 + 近場 (AWDL)"],
    ]
}
