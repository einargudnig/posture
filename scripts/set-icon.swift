import AppKit

// Sets a custom Finder icon on a file, folder or mounted volume.
//
// `.VolumeIcon.icns` plus `SetFile -a C` is the documented convention, but it
// did not take on a freshly created image here — the flag was set and the icon
// stayed generic. This is the same thing Finder's Get Info → paste icon does,
// and it works.
let args = CommandLine.arguments
guard args.count > 2,
      let icon = NSImage(contentsOfFile: args[1])
else {
    FileHandle.standardError.write(Data("usage: set-icon <icns> <target>\n".utf8))
    exit(1)
}
exit(NSWorkspace.shared.setIcon(icon, forFile: args[2], options: []) ? 0 : 2)
