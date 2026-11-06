<!-- @format -->

# JOSM ↔ Rapid Preset Converter

Convert the supported subset of JOSM tagging presets (XML) and Rapid (iD tagging schema) presets (JSON) in either direction. Requires Python 3.10+ and uses only the Python standard library.

## Usage

```powershell
python utilities/preset-converter/preset_converter.py josm-to-rapid path/to/presets.xml output-directory
python utilities/preset-converter/preset_converter.py rapid-to-josm path/to/rapid/data/presets output.xml --fields-dir path/to/rapid/data/fields
```

`josm-to-rapid` writes preset JSON for each convertible JOSM `<item>` under `output-directory/data/presets/` and reusable fields under `output-directory/data/fields/`. Use `--preset-id` to set the base ID (default: a slug of the XML filename) and `--overwrite` to replace generated files.

`rapid-to-josm` accepts a preset JSON file, a directory of preset JSON files, the Rapid `data/` directory, or a checkout. It discovers fields in the Rapid `data/fields/` layout; use `--fields-dir` for other field locations. `--overwrite` replaces an existing output XML file.

## Tests

Run from the repository root:

```powershell
python -m pytest utilities/preset-converter/tests
```

## Supported behavior

- Preset names, fixed tags, field-only presets (written with empty Rapid `tags`), reusable fields, and optional fields.
- Common text, combo/radio, checkbox, and multiselect/semiCombo fields; static options and display labels, including JOSM `<list_entry>` labels.
- Geometry mapping is lossy: JOSM `node` maps to Rapid `point`/`vertex`, `way` to `line`/`area`, `closedway`/`multipolygon` to `area`, and `relation` to `relation`; Rapid `point`/`vertex` map to JOSM `node`, `area` to both `closedway` and `multipolygon`, and `relation` to `relation`. JOSM items without `type` map to all Rapid geometries; items with only unsupported geometries are skipped.
- Rapid `multiCombo` is skipped with a warning because JOSM multiselect cannot represent its independent yes/no subtags.

## Limitations

This is a lossy converter, not a schema validator. JOSM group hierarchy is not preserved: group names become Rapid `terms`, while Rapid `terms` and `aliases` are not carried into JOSM. Translations, templates and inheritance, tag removals, location restrictions, prerequisites, scripts, dynamic options, many advanced JOSM elements, and less common Rapid field widgets are not converted. Icon references are copied as-is; icon assets and format differences are not handled. Review output and warnings before publishing.
