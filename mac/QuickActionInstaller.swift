import Foundation

enum QuickActionInstaller {
    private static let workflowName = "Отправить на Windows.workflow"

    static func installIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        DispatchQueue.global(qos: .utility).async {
            install(bundlePath: bundlePath)
        }
    }

    private static func install(bundlePath: String) {
        let fm = FileManager.default
        let servicesDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services", isDirectory: true)
        let workflowDir = servicesDir.appendingPathComponent(workflowName, isDirectory: true)
        let contentsDir = workflowDir.appendingPathComponent("Contents", isDirectory: true)
        let resourcesDir = contentsDir.appendingPathComponent("Resources", isDirectory: true)

        do {
            try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        } catch {
            Diagnostics.shared.record("quick action mkdir failed: \(error.localizedDescription)")
            return
        }

        let escapedBundle = xmlEscape(shellEscape(bundlePath))
        let script = """
        if [ -d "\(escapedBundle)" ]; then
            /usr/bin/open -g -a "\(escapedBundle)" -- "$@"
        else
            /usr/bin/open -g -b com.artlee12.prilo -- "$@"
        fi
        """

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>CFBundleDevelopmentRegion</key>
        \t<string>ru</string>
        \t<key>CFBundleIdentifier</key>
        \t<string>com.artlee12.prilo.finder-send</string>
        \t<key>CFBundleName</key>
        \t<string>Отправить на Windows</string>
        \t<key>CFBundleShortVersionString</key>
        \t<string>1.0</string>
        \t<key>NSServices</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>NSIconName</key>
        \t\t\t<string>NSShareTemplate</string>
        \t\t\t<key>NSMenuItem</key>
        \t\t\t<dict>
        \t\t\t\t<key>default</key>
        \t\t\t\t<string>Отправить на Windows</string>
        \t\t\t</dict>
        \t\t\t<key>NSMessage</key>
        \t\t\t<string>runWorkflowAsService</string>
        \t\t\t<key>NSRequiredContext</key>
        \t\t\t<dict>
        \t\t\t\t<key>NSApplicationIdentifier</key>
        \t\t\t\t<string>com.apple.finder</string>
        \t\t\t</dict>
        \t\t\t<key>NSSendFileTypes</key>
        \t\t\t<array>
        \t\t\t\t<string>public.item</string>
        \t\t\t</array>
        \t\t</dict>
        \t</array>
        </dict>
        </plist>
        """

        let documentWflow = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>AMApplicationBuild</key>
        \t<string>523</string>
        \t<key>AMApplicationVersion</key>
        \t<string>2.10</string>
        \t<key>AMDocumentVersion</key>
        \t<string>2</string>
        \t<key>actions</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>action</key>
        \t\t\t<dict>
        \t\t\t\t<key>AMAccepts</key>
        \t\t\t\t<dict>
        \t\t\t\t\t<key>Container</key>
        \t\t\t\t\t<string>List</string>
        \t\t\t\t\t<key>Optional</key>
        \t\t\t\t\t<true/>
        \t\t\t\t\t<key>Types</key>
        \t\t\t\t\t<array>
        \t\t\t\t\t\t<string>com.apple.cocoa.string</string>
        \t\t\t\t\t</array>
        \t\t\t\t</dict>
        \t\t\t\t<key>AMActionVersion</key>
        \t\t\t\t<string>2.0.3</string>
        \t\t\t\t<key>AMApplication</key>
        \t\t\t\t<array>
        \t\t\t\t\t<string>Automator</string>
        \t\t\t\t</array>
        \t\t\t\t<key>AMParameterProperties</key>
        \t\t\t\t<dict>
        \t\t\t\t\t<key>COMMAND_STRING</key>
        \t\t\t\t\t<dict/>
        \t\t\t\t\t<key>CheckedForUserDefaultShell</key>
        \t\t\t\t\t<dict/>
        \t\t\t\t\t<key>inputMethod</key>
        \t\t\t\t\t<dict/>
        \t\t\t\t\t<key>shell</key>
        \t\t\t\t\t<dict/>
        \t\t\t\t\t<key>source</key>
        \t\t\t\t\t<dict/>
        \t\t\t\t</dict>
        \t\t\t\t<key>AMProvides</key>
        \t\t\t\t<dict>
        \t\t\t\t\t<key>Container</key>
        \t\t\t\t\t<string>List</string>
        \t\t\t\t\t<key>Types</key>
        \t\t\t\t\t<array>
        \t\t\t\t\t\t<string>com.apple.cocoa.string</string>
        \t\t\t\t\t</array>
        \t\t\t\t</dict>
        \t\t\t\t<key>ActionBundlePath</key>
        \t\t\t\t<string>/System/Library/Automator/Run Shell Script.action</string>
        \t\t\t\t<key>ActionName</key>
        \t\t\t\t<string>Run Shell Script</string>
        \t\t\t\t<key>ActionParameters</key>
        \t\t\t\t<dict>
        \t\t\t\t\t<key>COMMAND_STRING</key>
        \t\t\t\t\t<string>\(script)</string>
        \t\t\t\t\t<key>CheckedForUserDefaultShell</key>
        \t\t\t\t\t<true/>
        \t\t\t\t\t<key>inputMethod</key>
        \t\t\t\t\t<integer>1</integer>
        \t\t\t\t\t<key>shell</key>
        \t\t\t\t\t<string>/bin/sh</string>
        \t\t\t\t\t<key>source</key>
        \t\t\t\t\t<string></string>
        \t\t\t\t</dict>
        \t\t\t\t<key>BundleIdentifier</key>
        \t\t\t\t<string>com.apple.RunShellScript</string>
        \t\t\t\t<key>CFBundleVersion</key>
        \t\t\t\t<string>2.0.3</string>
        \t\t\t\t<key>CanShowSelectedItemsWhenRun</key>
        \t\t\t\t<false/>
        \t\t\t\t<key>CanShowWhenRun</key>
        \t\t\t\t<false/>
        \t\t\t\t<key>Category</key>
        \t\t\t\t<array>
        \t\t\t\t\t<string>AMCategoryUtilities</string>
        \t\t\t\t</array>
        \t\t\t\t<key>Class Name</key>
        \t\t\t\t<string>RunShellScriptAction</string>
        \t\t\t\t<key>InputUUID</key>
        \t\t\t\t<string>54C5C1D6-38E4-4A43-B446-912D4E9F4A01</string>
        \t\t\t\t<key>Keywords</key>
        \t\t\t\t<array>
        \t\t\t\t\t<string>Shell</string>
        \t\t\t\t\t<string>Script</string>
        \t\t\t\t</array>
        \t\t\t\t<key>OutputUUID</key>
        \t\t\t\t<string>81E53067-990A-4259-BB3D-3FA9A1C93F87</string>
        \t\t\t\t<key>UUID</key>
        \t\t\t\t<string>C6BA9215-61BA-4E7D-992B-D5CA35CF5492</string>
        \t\t\t\t<key>UnlocalizedApplications</key>
        \t\t\t\t<array>
        \t\t\t\t\t<string>Automator</string>
        \t\t\t\t</array>
        \t\t\t</dict>
        \t\t</dict>
        \t</array>
        \t<key>connectors</key>
        \t<dict/>
        \t<key>workflowMetaData</key>
        \t<dict>
        \t\t<key>applicationBundleID</key>
        \t\t<string>com.apple.finder</string>
        \t\t<key>applicationBundleIDsByPath</key>
        \t\t<dict>
        \t\t\t<key>/System/Library/CoreServices/Finder.app</key>
        \t\t\t<string>com.apple.finder</string>
        \t\t</dict>
        \t\t<key>applicationPath</key>
        \t\t<string>/System/Library/CoreServices/Finder.app</string>
        \t\t<key>applicationPathsByApplication</key>
        \t\t<dict>
        \t\t\t<key>com.apple.finder</key>
        \t\t\t<string>/System/Library/CoreServices/Finder.app</string>
        \t\t</dict>
        \t\t<key>inputTypeIdentifier</key>
        \t\t<string>com.apple.Automator.fileSystemObject</string>
        \t\t<key>outputTypeIdentifier</key>
        \t\t<string>com.apple.Automator.nothing</string>
        \t\t<key>presentationMode</key>
        \t\t<integer>15</integer>
        \t\t<key>processesInput</key>
        \t\t<false/>
        \t\t<key>serviceApplicationBundleID</key>
        \t\t<string>com.apple.finder</string>
        \t\t<key>serviceApplicationPath</key>
        \t\t<string>/System/Library/CoreServices/Finder.app</string>
        \t\t<key>serviceInputTypeIdentifier</key>
        \t\t<string>com.apple.Automator.fileSystemObject</string>
        \t\t<key>serviceOutputTypeIdentifier</key>
        \t\t<string>com.apple.Automator.nothing</string>
        \t\t<key>serviceProcessesInput</key>
        \t\t<false/>
        \t\t<key>workflowTypeIdentifier</key>
        \t\t<string>com.apple.Automator.servicesMenu</string>
        \t</dict>
        </dict>
        </plist>
        """

        let targets = [
            (contentsDir.appendingPathComponent("Info.plist"), infoPlist),
            (contentsDir.appendingPathComponent("document.wflow"), documentWflow),
            (resourcesDir.appendingPathComponent("document.wflow"), documentWflow),
        ]

        var changed = false
        for (url, content) in targets {
            let existing = try? String(contentsOf: url, encoding: .utf8)
            if existing != content {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    changed = true
                } catch {
                    Diagnostics.shared.record("quick action write failed: \(error.localizedDescription)")
                    return
                }
            }
        }

        if changed {
            runUtility("/System/Library/CoreServices/pbs", args: ["-update"])
            runUtility("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                       args: ["-f", bundlePath])
            Diagnostics.shared.record("finder quick action installed")
        }
    }

    private static func runUtility(_ path: String, args: [String]) {
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
