# dmgbuild settings for Windowsill.dmg. scripts/package.sh runs:
#   dmgbuild -s scripts/dmg-settings.py -D app=<Windowsill.app> -D background=<background.png> Windowsill <out.dmg>
# dmgbuild writes the window's layout itself, so no Finder is needed (a CI Mac has no one to answer it).
# background.png is 640 x 400 points; dmgbuild pairs it with background@2x.png beside it for Retina screens.
# `defines` is the -D values, which dmgbuild hands to this file.
import os.path

app = defines["app"]  # noqa: F821
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Windowsill.app"]
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")  # the mounted disk shows the app's icon
format = "UDZO"

background = defines["background"]  # noqa: F821
window_rect = ((200, 200), (640, 400))
default_view = "icon-view"
show_icon_preview = False
icon_size = 112
text_size = 13
# Centres, matching the arrow painted between them (Resources/dmg).
icon_locations = {"Windowsill.app": (160, 200), "Applications": (480, 200)}
