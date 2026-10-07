import Foundation

/// The part of the update that outlives the process performing it.
///
/// Once the bundle has been swapped, the app has to die for the new one to start —
/// so the last steps run in a detached shell. Keeping the script here, away from the
/// `Process` that launches it, is what lets the recovery path be tested: the same
/// string runs against fake bundles and a fake launcher in `UpdateInstallationTests`.
enum UpdateInstallation {
    /// Open the freshly installed bundle, and put the old one back if it will not open.
    ///
    /// Arguments, all passed as arguments and never interpolated — this script runs
    /// `rm -rf`, and an app path is not something to hand to the shell's parser:
    /// `$1` the installed bundle, `$2` the staging dir, `$3` the backup of the old
    /// bundle, `$4` the launcher (`/usr/bin/open`, or a stand-in under test). The
    /// relaunch is marked `--background`: nobody clicked it, so it opens no window.
    ///
    /// The backup is deleted only after the new bundle has actually opened. If it
    /// refuses to, the backup is moved back into place and launched instead, and the
    /// staging dir is left behind so a failed update can still be looked at.
    static let relaunchScript = #"""
    sleep 0.6
    if "$4" -n "$1" --args --background; then
      /bin/rm -rf "$2" "$3"
      exit 0
    fi
    /bin/rm -rf "$1"
    /bin/mv "$3" "$1" || exit 1
    "$4" -n "$1" --args --background || exit 1
    /bin/rm -rf "$2"
    """#
}
