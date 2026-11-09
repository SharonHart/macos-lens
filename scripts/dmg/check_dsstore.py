"""Checks the Finder window settings in a mounted macOS Lens disk image and prints them as JSON.

Usage: check_dsstore.py <mount point> <layout.json> <app name> <volume name>

Fails if the window size, hidden bars, icon size, icon positions or background don't match the layout, or if the
background alias doesn't point at .background.tiff on this volume.
"""
import json
import os
import re
import sys

from ds_store import DSStore
from mac_alias import Alias
from mac_alias.bookmark import kBookmarkPath, kBookmarkVolumePath


def main():
    mount, layout_path, app_name, volume_name = sys.argv[1:5]
    with open(layout_path) as fp:
        layout = json.load(fp)
    problems = []

    def expect(ok, message):
        if not ok:
            problems.append(message)

    with DSStore.open(os.path.join(mount, ".DS_Store"), "r") as store:
        bwsp = store["."]["bwsp"]
        icvp = store["."]["icvp"]
        bookmark = store["."]["pBBk"]
        icons = {name: list(store[name]["Iloc"]) for name in (app_name, "Applications")}

    match = re.fullmatch(r"\{\{(-?\d+), (-?\d+)\}, \{(\d+), (\d+)\}\}", bwsp["WindowBounds"])
    expect(match, "unreadable WindowBounds %r" % bwsp["WindowBounds"])
    x, y, width, height = (int(v) for v in match.groups()) if match else (0, 0, 0, 0)
    expect([width, height] == layout["window"], "window is %dx%d" % (width, height))
    for key in ("ShowStatusBar", "ShowToolbar", "ShowSidebar", "ShowPathbar", "ShowTabView"):
        expect(bwsp.get(key) is False, "%s is %r" % (key, bwsp.get(key)))
    expect(icvp["backgroundType"] == 2, "backgroundType is %r" % icvp["backgroundType"])
    expect(icvp["iconSize"] == layout["icon_size"], "iconSize is %r" % icvp["iconSize"])
    expect(icvp["textSize"] == layout["text_size"], "textSize is %r" % icvp["textSize"])
    expect(icvp["arrangeBy"] == "none", "arrangeBy is %r" % icvp["arrangeBy"])
    expect(icons[app_name] == layout["app"], "app icon at %r" % icons[app_name])
    expect(icons["Applications"] == layout["applications"], "Applications at %r" % icons["Applications"])

    background = os.path.join(mount, ".background.tiff")
    alias = Alias.from_bytes(icvp["backgroundImageAlias"])
    expect(alias.volume.name == volume_name, "alias volume is %r" % alias.volume.name)
    expect(alias.target.filename == ".background.tiff", "alias file is %r" % alias.target.filename)
    expect(alias.target.cnid == os.stat(background).st_ino, "alias file id doesn't match .background.tiff")
    expect(alias.target.folder_cnid == os.stat(mount).st_ino, "alias folder id isn't the volume root")
    expect(os.fsdecode(alias.volume.posix_path) == mount, "alias volume path is %r" % alias.volume.posix_path)
    bookmark_volume = bookmark.tocs[0][1][kBookmarkVolumePath]
    expect(bookmark_volume == mount, "bookmark volume path is %r" % bookmark_volume)
    bookmark_path = bookmark.tocs[0][1][kBookmarkPath]
    expected_path = mount.strip("/").split("/") + [".background.tiff"]
    expect(bookmark_path == expected_path, "bookmark path is %r" % bookmark_path)

    dump = {
        "volume_name": volume_name,
        "window": {"x": x, "y": y, "width": width, "height": height},
        "show": {key: bwsp.get(key) for key in ("ShowStatusBar", "ShowToolbar", "ShowSidebar", "ShowPathbar", "ShowTabView")},
        "icon_size": icvp["iconSize"],
        "text_size": icvp["textSize"],
        "background_type": icvp["backgroundType"],
        "icons": icons,
        "alias": {"volume": alias.volume.name, "volume_path": os.fsdecode(alias.volume.posix_path),
                  "file": alias.target.filename, "cnid": alias.target.cnid,
                  "folder_cnid": alias.target.folder_cnid, "hex": icvp["backgroundImageAlias"].hex()},
        "bookmark_volume_path": bookmark_volume,
        "bookmark_path": "/" + "/".join(bookmark_path),
        "bookmark_hex": bookmark.to_bytes().hex(),
    }
    print(json.dumps(dump, indent=2))
    if problems:
        sys.exit("The disk image's Finder settings are wrong:\n  " + "\n  ".join(problems))


if __name__ == "__main__":
    main()
