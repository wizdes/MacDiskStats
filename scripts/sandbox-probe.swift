import Foundation
import Darwin
import DiskCore

func tryWrite(_ path: String) -> Bool {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    if fd < 0 { return false }
    close(fd); unlink(path); return true
}
guard let user = getpwuid(getuid()), let homePointer = user.pointee.pw_dir else {
    fputs("real home lookup failed\n", stderr); exit(1)
}
let home = String(cString: homePointer)
let tree = try await Scanner.scan(root: home)
print("scan total \(tree.countedSize[0]) files \(tree.filesSeen) unreadable \(tree.unreadablePaths.count)")
let token = UUID().uuidString
print("real home write refused \(!tryWrite(home + "/.cushion-probe-" + token))")
print("/tmp write refused \(!tryWrite("/tmp/.cushion-probe-" + token))")
print("real Documents write refused \(!tryWrite(home + "/Documents/.cushion-probe-" + token))")
