<!-- @format -->

# TDEI Tools

Repository for tools and resources related to the Transportation Data Exchange Initiative (TDEI).

## [Images](images)

Images of pedestrian infrastructure and related features, intended to be used in AVIV ScoutRoute long form quest definitions. Uncropped original non-annotated images are included, and all of the images in the `/images/` directory and all of its subdirectories are CC0-licensed and free to use by anyone for any purpose unless otherwise noted.

Note that the intent of this resource is to facilitate the functioning of the AVIV ScoutRoute app. If you have images that you think would be useful to add - please upload them to [Wikimedia Commons](https://commons.wikimedia.org/wiki/Main_Page)!

## [Utilities](utilities)

Utilities related to the TDEI.

- **[GTFS-to-TDEI Converter Script](utilities/gtfs_to_tdei_converter.py)** — Converts a GTFS `stops.txt` file to OpenSidewalks schema v0.3 GeoJSON and packages it as a dated ZIP ready for upload to the TDEI. The ZIP contains one file named `YYYY-MM-DD_GTFS_OSW.points.geojson`.

Run the converter from the repository root, with the path to the GTFS ZIP as the required positional parameter, and optionally with the `--output-dir` (or `-o`) parameter:

```text
python utilities/gtfs_to_tdei_converter.py "C:/data/google_transit.zip" --o "C:/data/output"
```

- **[List Members Script](utilities/list-members.py)** — Exports a CSV of member names and email addresses for a TDEI project group. Requires Point of Contact (poc) role authorization.

- **[Set Line Endings Script](utilities/set-line-endings.ps1)** — Converts line endings in files to LF (Unix) or CRLF (Windows), with optional recursive directory processing.

- **[SLI Guardian](utilities/sli-guardian.ps1)** — Applies overlay images to street-level imagery (e.g., from GoPro Max cameras), processing in parallel batches while preserving EXIF metadata.

- **[TDEI Tools Images Exif Data Update Script](utilities/update-exif.ps1)** — Removes all existing EXIF metadata from PNG files and adds standardized CC0 Public Domain Dedication copyright tags.

- **[Workspaces Export Script](utilities/workspaces-export.ps1)** — Exports a complete dataset from a TDEI Workspaces environment to an `.osm` file using the Workspaces API.

- **[Workspaces JOSM Settings Script](utilities/workspaces-josm.ps1)** — Retrieves JOSM configuration settings for editing a TDEI Workspace by authenticating via the Workspaces API.
