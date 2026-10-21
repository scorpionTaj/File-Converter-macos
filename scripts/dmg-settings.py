# dmgbuild settings for Kumquat's installer window.
#   dmgbuild -s scripts/dmg-settings.py -D app=build/Kumquat.app -D background=... -D icon=... "Kumquat" build/Kumquat.dmg
# `defines` is provided by dmgbuild.
import os.path

application = defines.get("app", "build/Kumquat.app")  # noqa: F821
appname = os.path.basename(application)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [appname]

icon = defines.get("icon")  # noqa: F821  (volume icon)
background = defines.get("background")  # noqa: F821

# Window: 640×400 content, no toolbar/sidebar, two big icons with an arrow between them.
window_rect = ((200, 140), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = 128
icon_locations = {
    appname: (160, 210),
    "Applications": (480, 210),
}
