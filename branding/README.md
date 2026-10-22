# Branding: name, app IDs, icon

This folder decides what the three apps (web, Android, iOS) are called and what they look like. The default is **FreeChat**: a speech bubble with a padlock on a green background.

## What to change

| File | Contents |
|---|---|
| `branding.conf` | App name, Android application ID, iOS bundle ID, icon background colour, web theme colour |
| `icon.png` | The symbol on the icon: **1024×1024**, **transparent background**. Keep it inside the central two thirds: Android crops icons to circles and other shapes, so the edges may be cut off |

Don't paint the background into `icon.png`; `ICON_BACKGROUND` in `branding.conf` sets it.

## Applying it

```bash
python3 branding/apply.py            # every client that has been checked out
python3 branding/apply.py android    # Android only (or ios, web)
python3 branding/apply.py --default-icon   # go back to the default icon
```

Needs Pillow: `python3 -m pip install --user pillow`.

Builds also apply it on their own:
- Android: `dev/build-android.sh`
- iOS: `dev/build-ios.sh` (on a Mac)
- Web: when the Docker image is built (`docker/web.Dockerfile`, which the GitHub build uses too)

The name shown in the web client is set separately by the installer's `--brand` option (FreeChat by default).

## Notes

- **Don't change the Android application ID once people have installed the app**: it would count as a different app, and everyone would have to uninstall and reinstall, losing local data.
- The iOS bundle ID must match the one registered in your Apple developer account; check it before publishing.
- After changing the icon or name, rebuild and reinstall the apps to see it.
