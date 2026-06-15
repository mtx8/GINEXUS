// udsprobe — verify the UDS client against the live MTX-NEXUS sidecar from the shell.
//   udsprobe [socketPath] [path]
// Defaults to the brainstem socket + /healthz. Exit 0 iff HTTP 2xx.
import Foundation
import GinexusCore

let home = FileManager.default.homeDirectoryForCurrentUser.path
let defaultSock = "\(home)/Library/Application Support/NEXUSBrainstem/run/brainstem.sock"
let sock = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultSock
let path = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/healthz"

switch UDSClient.request(socketPath: sock, path: path) {
case .success(let r):
    print("HTTP \(r.status)  \(path)")
    print(r.body)
    exit(r.status >= 200 && r.status < 300 ? 0 : 1)
case .failure(let e):
    FileHandle.standardError.write(Data("UDS error: \(e)\n".utf8))
    exit(2)
}
