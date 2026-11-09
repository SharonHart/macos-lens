# dmgbuild settings for the macOS Lens disk image. scripts/make-dmg.sh passes the paths with -D; the layout comes
# from the art tool so the icon positions always match the background it drew.
import json
import os

app = defines["app"]
art = defines["art"]
with open(os.path.join(art, "layout.json")) as fp:
    layout = json.load(fp)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]
background = os.path.join(art, "background.tiff")

default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
label_pos = "bottom"
icon_size = layout["icon_size"]
text_size = layout["text_size"]
window_rect = ((200, 120), tuple(layout["window"]))
icon_locations = {
    os.path.basename(app.rstrip("/")): tuple(layout["app"]),
    "Applications": tuple(layout["applications"]),
}
