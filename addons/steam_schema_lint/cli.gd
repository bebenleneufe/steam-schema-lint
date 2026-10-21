extends SceneTree
## CLI du palier gratuit — utilisable sans éditeur, donc en CI.
##
##   godot --headless --path . --script res://addons/steam_schema_lint/cli.gd -- check
##   godot --headless --path . --script res://addons/steam_schema_lint/cli.gd -- export --out steam/achievements.txt
##   godot --headless --path . --script res://addons/steam_schema_lint/cli.gd -- import --vdf brut.txt --out steam/steam_schema.json
##
## Options : --schema <chemin> (défaut res://steam/steam_schema.json),
##           --scan <dossier> (défaut res://, addons/ ignorés),
##           --out <chemin>, --vdf <chemin>.
##
## Codes de sortie : 0 tout va bien, 1 problèmes trouvés, 2 usage ou entrée illisible.

const SchemaModel = preload("res://addons/steam_schema_lint/schema_model.gd")
const Validator = preload("res://addons/steam_schema_lint/validator.gd")
const VdfWriter = preload("res://addons/steam_schema_lint/vdf_writer.gd")
const VdfReader = preload("res://addons/steam_schema_lint/vdf_reader.gd")
const Scanner = preload("res://addons/steam_schema_lint/code_scanner.gd")

const DEFAULT_SCHEMA := "res://steam/steam_schema.json"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		_usage()
		quit(2)
		return
	var command: String = args[0]
	var options := _parse_options(args.slice(1))

	match command:
		"check":
			quit(_cmd_check(options))
		"export":
			quit(_cmd_export(options))
		"import":
			quit(_cmd_import(options))
		"help", "--help", "-h":
			_usage()
			quit(0)
		_:
			printerr("Unknown command: %s" % command)
			_usage()
			quit(2)


# --- Commandes ----------------------------------------------------------------

func _cmd_check(options: Dictionary) -> int:
	var model = _load_model(options)
	if model == null:
		return 2

	var issues: Array = Validator.validate(model)
	var scan_dir := str(options.get("scan", "res://"))
	var scan: Dictionary = Scanner.scan_project(model, scan_dir)

	var errors := 0
	var warnings := 0
	for issue in issues:
		if issue["severity"] == "error":
			errors += 1
		else:
			warnings += 1
		print("%-6s %-28s %s" % [issue["severity"].to_upper(), issue["code"], issue["message"]])

	if scan["ok"]:
		for f in scan["findings"]:
			var where := "%s:%d" % [str(f["file"]).get_file(), int(f["line"])] if int(f["line"]) > 0 else str(f["api_name"])
			if f["severity"] == "error":
				errors += 1
			else:
				warnings += 1
			print("%-6s %-28s %s — %s" % [f["severity"].to_upper(), f["code"], where, f["message"]])
	else:
		for e in scan["errors"]:
			print("NOTE   %s" % e)

	print("")
	print("%d achievement(s), %d stat(s), %d script(s) scanned, %d error(s), %d warning(s)" % [
		model.achievements.size(), model.stats.size(),
		int(scan.get("files_scanned", 0)), errors, warnings])
	return 1 if errors > 0 else 0


func _cmd_export(options: Dictionary) -> int:
	var model = _load_model(options)
	if model == null:
		return 2
	var out := str(options.get("out", "res://steam/achievements_VDF.txt"))
	var result: Dictionary = VdfWriter.export_file(model, out, Validator)
	for e in result["errors"]:
		printerr("ERROR  %s" % e)
	for w in result["warnings"]:
		print("WARN   %s" % w)
	if result["ok"]:
		print("Written: %s" % out)
		return 0
	return 1


func _cmd_import(options: Dictionary) -> int:
	var vdf_path := str(options.get("vdf", ""))
	if vdf_path.is_empty():
		printerr("ERROR  import needs --vdf <file>")
		return 2
	if not FileAccess.file_exists(vdf_path):
		printerr("ERROR  cannot read %s" % vdf_path)
		return 2

	var text := FileAccess.get_file_as_string(vdf_path)
	var result: Dictionary = VdfReader.import_text(text)
	if not result["ok"]:
		for e in result["errors"]:
			printerr("ERROR  %s" % e)
		return 1

	var model = result["model"]
	var out := str(options.get("out", DEFAULT_SCHEMA))
	if not model.save_file(out):
		printerr("ERROR  %s" % model.last_error)
		return 1
	print("Imported %d achievement(s) and %d stat(s) into %s" % [
		model.achievements.size(), model.stats.size(), out])
	for w in result["warnings"]:
		print("WARN   %s" % w)
	return 0


# --- Utilitaires --------------------------------------------------------------

func _load_model(options: Dictionary):
	var path := str(options.get("schema", DEFAULT_SCHEMA))
	var model = SchemaModel.new()
	if not model.load_file(path):
		printerr("ERROR  %s" % model.last_error)
		return null
	return model


func _parse_options(args: Array) -> Dictionary:
	var options := {}
	var i := 0
	while i < args.size():
		var arg := str(args[i])
		if arg.begins_with("--"):
			var key := arg.substr(2)
			if i + 1 < args.size():
				options[key] = str(args[i + 1])
				i += 2
				continue
			options[key] = ""
		i += 1
	return options


func _usage() -> void:
	print("steam_schema_lint — check, export and import Steamworks achievements from the command line")
	print("")
	print("  check   validate the schema and scan the project for broken Steam calls")
	print("  export  write the VDF that Steamworks imports")
	print("  import  rebuild the schema from a raw Stats block copied out of Steamworks")
	print("")
	print("Options: --schema <path> --scan <dir> --out <path> --vdf <path>")
	print("Exit codes: 0 clean, 1 problems found, 2 usage or unreadable input")
