//
//  OnePasswordTokenRequester.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 3/20/22.
//

import Foundation

class OnePasswordUtils {
    static let basicEnvironment = ["HOME": NSHomeDirectory()]
    private static var _customPathToCLI: String? = nil
    private(set) static var usable: Bool? = nil

    static var pathToCLI: String {
        if let customPath = _customPathToCLI {
            return customPath
        }
        let normalPath = "/usr/local/bin/op"
        lazy var normalPathExists = {
            return FileManager.default.fileExists(atPath: normalPath)
        }()
        if normalPathExists {
            DLog("normal path exists")
            if usable == nil && !checkUsability(normalPath) {
                DLog("usability fail")
                usable = false
                showUnavailableMessage(normalPath)
            } else {
                DLog("normal path ok")
                usable = true
                return normalPath
            }
        }
        if showCannotFindCLIMessage() {
            _customPathToCLI = askUserToFindCLI()
            if let path = _customPathToCLI {
                usable = checkUsability(path)
                if usable == false {
                    showUnavailableMessage()
                }
            }
        }
        return _customPathToCLI ?? normalPath
    }

    static func throwIfUnusable() throws {
        _ = pathToCLI
        if usable == false {
            throw OnePasswordDataSource.OPError.unusableCLI
        }
    }

    static func resetErrors() {
        if usable == false {
            usable = nil
            _customPathToCLI = nil
        }
    }
    static func checkUsability() -> Bool {
        return checkUsability(pathToCLI)
    }

    private static func checkUsability(_ path: String) -> Bool {
        return majorVersionNumber(path) == 2
    }

    static func showUnavailableMessage(_ path: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "OnePassword Unavailable"
        if let path = path {
            alert.informativeText = "The existing installation of the OnePassword CLI at \(path) is an incompatible. The iTerm2 integration requires version 2."
        } else {
            alert.informativeText = "Version 2 of the OnePassword CLI could not be found. Check that \(OnePasswordUtils.pathToCLI) is installed and has version 2.x."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // Returns true to show an open panel to locate it.
    private static func showCannotFindCLIMessage() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Can’t Find 1Password CLI"
        alert.informativeText = "In order to use the 1Password integration, iTerm2 needs to know where to find the CLI app named “op”. It’s normally in /usr/local/bin. If you have installed it elsewhere, please select Locate to provide its location."
        alert.addButton(withTitle: "Locate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func askUserToFindCLI() -> String? {
        class OnePasswordCLIFinderOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
            func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
                if FileManager.default.itemIsDirectory(url.path) {
                    return true
                }
                return url.lastPathComponent == "op"
            }
        }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = [ "" ]
        let delegate = OnePasswordCLIFinderOpenPanelDelegate()
        return withExtendedLifetime(delegate) {
            panel.delegate = delegate
            if panel.runModal() == .OK,
                let url = panel.url,
                url.lastPathComponent == "op" {
                return url.path
            }
            return nil
        }
    }

    static func standardEnvironment(token: OnePasswordTokenRequester.Auth) -> [String: String] {
        var result = OnePasswordUtils.basicEnvironment
        switch token {
        case .biometric:
            break
        case .token(let token):
            result["OP_SESSION_my"] = token
        }
        return result
    }

    static func majorVersionNumber() -> Int? {
        return majorVersionNumber(pathToCLI)
    }

    private static func majorVersionNumber(_ pathToCLI: String) -> Int? {
        let maybeData = try? CommandLinePasswordDataSource.InteractiveCommandRequest(
            command: pathToCLI,
            args: ["-v"],
            env: [:]).exec().stdout
        if let data = maybeData, let string = String(data: data, encoding: .utf8) {
            var value = 0
            DLog("version string is \(string)")
            if Scanner(string: string).scanInt(&value) {
                DLog("scan returned \(value)")
                return value
            }
            DLog("scan failed")
            return nil
        }
        DLog("Didn't get a version number")
        return nil
    }
}

class OnePasswordTokenRequester {
    private var token = ""
    private static var biometricsAvailable: Bool? = nil

    enum Auth {
        case biometric
        case token(String)
    }

    // Returns nil if a token is unneeded because biometric authentication is available.
    func get() throws -> Auth {
        if Self.biometricsAvailable == nil {
            switch checkBiometricAvailability() {
            case .some(true):
                DLog("biometrics are available")
                return .biometric
            case .some(false):
                DLog("biometrics unavailable")
                break
            case .none:
                throw OnePasswordDataSource.OPError.canceledByUser
            }
        }
        guard let password = self.requestPassword(prompt: "Enter your 1Password master password:") else {
            throw OnePasswordDataSource.OPError.canceledByUser
        }
        let command = CommandLinePasswordDataSource.CommandRequestWithInput(
            command: OnePasswordUtils.pathToCLI,
            args: ["signin", "--raw"],
            env: OnePasswordUtils.basicEnvironment,
            input: (password + "\n").data(using: .utf8)!)
        let output = try command.exec()
        if output.returnCode != 0 {
            DLog("signin failed")
            let reason = String(data: output.stderr, encoding: .utf8) ?? "An unknown error occurred."
            if reason.contains("connecting to desktop app timed out") {
                throw OnePasswordDataSource.OPError.unusableCLI
            }
            showErrorMessage(reason)
            throw OnePasswordDataSource.OPError.needsAuthentication
        }
        guard let token = String(data: output.stdout, encoding: .utf8) else {
            DLog("got garbage output")
            showErrorMessage("The 1Password CLI app produced garbled output instead of an auth token.")
            throw OnePasswordDataSource.OPError.badOutput
        }
        return .token(token.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
    }

    private func showErrorMessage(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Authentication Error"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func requestPassword(prompt: String) -> String? {
        DLog("requesting master password")
        return ModalPasswordAlert(prompt).run(window: nil)
    }

    // Returns nil if it was canceled by the user.
    func checkBiometricAvailability() -> Bool? {
        // Issue a command that is doomed to fail so we can see what the error message looks like.
        let cli = OnePasswordUtils.pathToCLI
        if OnePasswordUtils.usable != true {
           DLog("No usable version of 1password's op utility was found")
            // Don't ask for the master password if we don't have a good CLI to use.
            return nil
        }
        let command = CommandLinePasswordDataSource.InteractiveCommandRequest(
            command: cli,
            args: ["user", "get", "--me"],
            env: OnePasswordUtils.basicEnvironment)
        let output = try! command.exec()
        if output.returnCode == 0 {
            DLog("op user get --me succeeded so biometrics must be available")
            return true
        }
        guard let string = String(data: output.stderr, encoding: .utf8) else {
            DLog("garbage output")
            return false
        }
        DLog("op signin returned \(string)")
        if string.contains("error initializing client: authorization prompt dismissed, please try again") {
            return nil
        }
        return false
    }
}
