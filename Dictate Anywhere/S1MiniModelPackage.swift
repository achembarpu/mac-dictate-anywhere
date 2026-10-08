import Foundation

nonisolated struct S1MiniModelAsset: Sendable {
    let filename: String
    let byteCount: Int64
    let sha256: String
    let repository: String
    let revision: String

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)?download=true")!
    }
}

nonisolated enum S1MiniRuntime: String, Sendable {
    case llama, mlx

    static var recommended: Self {
        #if arch(arm64)
        .mlx
        #else
        .llama
        #endif
    }

    var assets: [S1MiniModelAsset] {
        let licenseRepository = "superwhisper/s1-mini"
        let licenseRevision = "88f6b15896c73bbb13a3b596e0afe8ea0d5150b4"
        let notices = [
            S1MiniModelAsset(filename: "LICENSE", byteCount: 12033,
                sha256: "f715982df6ce767ae64864d74b95644e5d658aab54717dbceeb252eb3cbcb421",
                repository: licenseRepository, revision: licenseRevision),
            S1MiniModelAsset(filename: "NOTICE", byteCount: 470,
                sha256: "4feae786f1766dc58e807bcae1e7bdd06bf3610a03a23d0621b6c6c4d05f2980",
                repository: licenseRepository, revision: licenseRevision)
        ]
        switch self {
        case .llama:
            return [S1MiniModelAsset(filename: S1MiniModelSpec.filename, byteCount: S1MiniModelSpec.byteCount,
                sha256: S1MiniModelSpec.sha256, repository: S1MiniModelSpec.repository,
                revision: S1MiniModelSpec.revision)] + notices
        case .mlx:
            let files: [(String, Int64, String)] = [
                ("model.safetensors", 335450548, "284990f04854426d6164d634d8c472d7eb6e79c68f8fd8b4c8a80a4f234276ba"),
                ("config.json", 1021, "d8cbd096f758add51a940656710a0319cfb3ad4ae4591507ab29c2e8bebecc54"),
                ("tokenizer.json", 11422650, "be75606093db2094d7cd20f3c2f385c212750648bd6ea4fb2bf507a6a4c55506"),
                ("tokenizer_config.json", 729, "ee8f6d44bf2353e6d3686c3adaf70e1ccfe9e6ed6822d0ab2f28cafdd7754792"),
                ("chat_template.jinja", 4168, "a55ee1b1660128b7098723e0abcd92caa0788061051c62d51cbe87d9cf1974d8"),
                ("generation_config.json", 181, "6ca52b0bcb818c9e52db8ea18413494110c5f2def581b769f621dda951a7863b"),
                ("model.safetensors.index.json", 49770, "5ee67e4efeb75dfacb8dd3892dd6208473771264fdeff6b9eba4a79db5b1435e")
            ]
            return files.map { S1MiniModelAsset(filename: $0.0, byteCount: $0.1, sha256: $0.2,
                repository: "mlx-community/S1-mini-MLX-4bit", revision: "5cbd7aec3401144f88a331d385c40b65fd2548eb") } + notices
        }
    }

    var downloadByteCount: Int64 { assets.reduce(0) { $0 + $1.byteCount } }
    func directory(in root: URL) -> URL { root.appendingPathComponent(rawValue, isDirectory: true) }
    func modelURL(in root: URL) -> URL {
        let directory = directory(in: root)
        return self == .mlx ? directory : directory.appendingPathComponent(S1MiniModelSpec.filename)
    }
}
