"""Runs dmgbuild with its writable image mounted outside /Volumes.

Usage: build.py --settings <settings.py> --mount-dir <empty dir> [-D key=value ...] <volume name> <output.dmg>

Endpoint data-loss-prevention agents (Microsoft Defender's, for one) treat a writable disk image mounted under /Volumes
as removable media: once files are written to it they refuse to let it unmount, and dmgbuild's detach fails with
"Resource busy". Mounting the image at a private directory instead keeps it out of their way. The background alias
and bookmark that Finder reads from .DS_Store record the volume's mount point, so they are rewritten to
/Volumes/<volume name>, where Finder mounts the finished image, as dmgbuild records when it mounts there itself. The
bookmark also gets the full path Finder would record, since mac_alias's volume-relative one doesn't resolve.
scripts/make-dmg.sh then mounts the finished image read-only at that path and resolves both.
"""
import argparse
import os
from urllib.parse import quote

import dmgbuild
import dmgbuild.core as core
from mac_alias import Alias, Bookmark
from mac_alias.bookmark import (URL, kBookmarkCNIDPath, kBookmarkContainingFolder, kBookmarkPath,
                                 kBookmarkVolumePath, kBookmarkVolumeURL)

assert dmgbuild.__version__ == "1.6.5", "build.py was written against dmgbuild 1.6.5; check it before upgrading."


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--settings", required=True)
    parser.add_argument("--mount-dir", required=True)
    parser.add_argument("-D", dest="defines", action="append", default=[])
    parser.add_argument("volume_name")
    parser.add_argument("filename")
    args = parser.parse_args()
    defines = dict(define.split("=", 1) for define in args.defines)

    private_mount = os.path.realpath(args.mount_dir)
    os.makedirs(private_mount, exist_ok=True)
    finder_mount = "/Volumes/" + args.volume_name
    attaches = []

    hdiutil = core.hdiutil

    def private_hdiutil(cmd, *rest, **kwargs):
        if cmd == "attach":
            attaches.append(rest)
            rest = ("-mountpoint", private_mount) + rest
        return hdiutil(cmd, *rest, **kwargs)

    def on_volume(path):
        if not os.path.realpath(path).startswith(private_mount + os.sep):
            raise SystemExit("%s isn't on the private mount %s." % (path, private_mount))

    class FinderAlias(Alias):
        @classmethod
        def for_file(cls, path):
            on_volume(path)
            alias = Alias.for_file(path)
            if os.path.realpath(os.fsdecode(alias.volume.posix_path)) != private_mount:
                raise SystemExit("Unexpected alias volume path %r." % alias.volume.posix_path)
            alias.volume.posix_path = os.fsencode(finder_mount)
            return alias

    class FinderBookmark(Bookmark):
        @classmethod
        def for_file(cls, path):
            on_volume(path)
            bookmark = Bookmark.for_file(path)
            toc = bookmark.tocs[0][1]
            if os.path.realpath(toc[kBookmarkVolumePath]) != private_mount or len(toc[kBookmarkPath]) != 1:
                raise SystemExit("Unexpected bookmark: volume %r, path %r." % (toc[kBookmarkVolumePath], toc[kBookmarkPath]))
            # mac_alias records the path relative to the volume, which CFURL can't resolve. Record the full path the
            # way Finder does, with the IDs of /Volumes, the volume root and the file.
            relative = toc[kBookmarkPath]
            toc[kBookmarkPath] = finder_mount.strip("/").split("/") + relative
            toc[kBookmarkCNIDPath] = [os.stat("/Volumes").st_ino, os.stat(private_mount).st_ino] + toc[kBookmarkCNIDPath]
            toc[kBookmarkContainingFolder] = len(toc[kBookmarkPath]) - 2
            toc[kBookmarkVolumePath] = finder_mount
            toc[kBookmarkVolumeURL] = URL("file://" + quote(finder_mount) + "/")
            return bookmark

    core.hdiutil = private_hdiutil
    core.Alias = FinderAlias
    core.Bookmark = FinderBookmark
    dmgbuild.build_dmg(args.filename, args.volume_name, args.settings, defines=defines, detach_retries=5)
    if len(attaches) != 1:
        raise SystemExit("Expected dmgbuild to attach the image once, but it attached it %d times." % len(attaches))


if __name__ == "__main__":
    main()
