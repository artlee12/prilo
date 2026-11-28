import AppKit
import CryptoKit
import Darwin

struct PowerAccess {
    let profile: PCProfile
    let secrets: PCSecrets

    var code: String { powerCode(accessCode: secrets.code) }

    func request(lock: Bool, _ completion: @escaping (Response) -> Void) {
        let path = lock ? "lock" : "status"
        guard let url = URL(string: "https://\(profile.host):43821/power/\(path)") else {
            completion(.failure(.badURL))
            return
        }
        let connection = Connection(url: url, code: code, fingerprint: secrets.fingerprint)
        connection.perform(method: lock ? "POST" : "GET", completion: completion)
    }

    /// Turns the VPN on or off through Happ on the Windows PC.
    func vpn(connect: Bool, _ completion: @escaping (Response) -> Void) {
        guard let url = URL(string: "https://\(profile.host):43821/vpn/\(connect ? "connect" : "disconnect")") else {
            completion(.failure(.badURL))
            return
        }
        Connection(url: url, code: code, fingerprint: secrets.fingerprint).perform(method: "POST", completion: completion)
    }

    func homebridgeConfig(wake: WakeTarget) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "accessory": "PriloPC",
            "name": profile.name,
            "uuid_base": profile.id.uuidString,
            "host": profile.host,
            "mac": wake.mac,
            "broadcast": wake.broadcast,
            "powerToken": code,
            "fingerprint": secrets.fingerprint
        ], options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension Response {
    /// Explains why the Windows receiver could not be reached, or nil for other results.
    var unreachableHint: String? {
        guard case .failure(let code) = self else { return nil }
        switch code {
        case .timedOut:
            return "ПК не ответил на порту 43821. Если Fuso находит ПК в сети, подключение, скорее всего, блокирует брандмауэр Windows: в меню Fuso в трее выбери «Разрешить в брандмауэре…». Иначе проверь, что ПК включён и в той же сети."
        case .cannotConnectToHost:
            return "ПК в сети, но приёмник не принимает подключения. Запусти Fuso Receiver на Windows."
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed:
            return "Нет связи с ПК. Проверь, что Mac и ПК в одной сети и у Fuso есть доступ к локальной сети в настройках macOS."
        default:
            return nil
        }
    }
}
