# Steam Schema Lint

The free core of Steam Achievements Studio: your Steamworks achievements and
stats in one JSON file, validated and exported in the format Steamworks imports.
No editor UI. MIT licensed.

## What it does

- **Validate** a schema: API name rules, bit collisions, the 32-per-group limit,
  missing English text, stat types and ranges.
- **Write** the Stats VDF Steamworks accepts, in the exact shape it expects.
- **Read** the raw Stats block of a game you already shipped. Bit indices and the
  icon hashes Steam assigned are preserved, never renumbered.
- **Scan** your GDScript: unknown achievement names, `setStatInt` on a FLOAT
  stat, names built at runtime, achievements never unlocked.

## Install

Copy `addons/steam_schema_lint/` into your project. Nothing to enable, there is
no interface.

## Use

```bash
godot --headless --script res://addons/steam_schema_lint/cli.gd -- check --scan res://game
godot --headless --script res://addons/steam_schema_lint/cli.gd -- export --out res://steam/achievements_VDF.txt
```

`check` exits with code 1 when it finds an error, so a CI step fails on a typo
before an upload does.

## In CI

```yaml
- run: godot --headless --script res://addons/steam_schema_lint/cli.gd -- check --scan res://game
```

## License

MIT. See `LICENSE`. Use it, fork it, ship it in commercial projects, keep the
copyright notice.

## Related

The editor dock, the icon pipeline and the per-language form are the paid
version: [Steam Achievements Studio](https://deliriumt.itch.io/steam-achievements-studio).
