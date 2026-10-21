# Steam Schema Lint

Validates a Steamworks achievements schema, writes the Stats VDF Steamworks
imports, reads the raw Stats block of a shipped game, and scans GDScript for
achievement names that can never unlock.

Godot 4, MIT licensed, command line only.

Install: copy `addons/steam_schema_lint/` into your project.

```bash
godot --headless --script res://addons/steam_schema_lint/cli.gd -- check --scan res://game
```

Full documentation: [`addons/steam_schema_lint/README.md`](addons/steam_schema_lint/README.md).
