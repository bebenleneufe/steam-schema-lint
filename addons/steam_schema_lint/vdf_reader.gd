@tool
extends RefCounted
## Import d'un VDF existant (M6).
##
## Le cas d'usage : un jeu déjà publié sur Steam a ses achievements définis dans
## le back-end Steamworks. Sans import, adopter l'outil signifie tout ressaisir —
## donc personne ne l'adopte. On relit ici le bloc copié depuis
## *Apps & Packages → All Applications → Steamworks Admin → Misc → View Raw
## Settings → Stats*, et on reconstruit le schéma.
##
## Parseur KeyValues autonome : chaînes entre guillemets ou nues, accolades
## imbriquées, commentaires `//`, échappements `\"` `\\` `\n` `\t`. Il ne prétend
## pas couvrir tout le format — il couvre ce que Steamworks produit.

const SchemaModel = preload("res://addons/steam_schema_lint/schema_model.gd")


## Découpe puis assemble un fichier KeyValues.
## Retourne { ok: bool, root: Dictionary, errors: Array[String] }
static func parse(text: String) -> Dictionary:
	var result := {"ok": false, "root": {}, "errors": []}
	var tok := _tokenize(text)
	if not tok["ok"]:
		result["errors"] = tok["errors"]
		return result
	var tokens: Array = tok["tokens"]
	if tokens.is_empty():
		result["errors"].append("EMPTY_VDF: the file contains no token.")
		return result

	var root := {}
	var i := 0
	while i < tokens.size():
		if tokens[i]["t"] != "str":
			result["errors"].append("STRUCTURE: expected a key at token %d, found %s." % [i, tokens[i]["t"]])
			return result
		var key: String = tokens[i]["v"]
		i += 1
		if i >= tokens.size() or tokens[i]["t"] != "{":
			result["errors"].append("STRUCTURE: key \"%s\" is not followed by an object." % key)
			return result
		var sub := _parse_object(tokens, i)
		if not sub["ok"]:
			result["errors"].append(sub["error"])
			return result
		root[key] = sub["value"]
		i = sub["next"]

	result["ok"] = true
	result["root"] = root
	return result


## Reconstruit un schéma complet depuis le texte d'un VDF.
## Retourne { ok, model, errors: Array[String], warnings: Array[String] }
static func import_text(text: String, source_path := "") -> Dictionary:
	var out := {"ok": false, "model": null, "errors": [], "warnings": []}

	var parsed := parse(text)
	if not parsed["ok"]:
		out["errors"] = parsed["errors"]
		return out
	var root: Dictionary = parsed["root"]
	if root.is_empty():
		out["errors"].append("EMPTY_VDF: no top-level key.")
		return out

	# La racine est l'appid, et c'est l'objet qui contient `stats`.
	var appid := ""
	var app: Dictionary = {}
	for key in root.keys():
		var value: Variant = root[key]
		if typeof(value) == TYPE_DICTIONARY and (value as Dictionary).has("stats"):
			appid = str(key)
			app = value
			break
	if app.is_empty():
		out["errors"].append("NO_STATS_SECTION: no top-level object contains a \"stats\" section — is this really the Stats block from View Raw Settings?")
		return out

	var stats: Dictionary = app.get("stats", {})
	if stats.is_empty():
		out["errors"].append("EMPTY_STATS: the \"stats\" section is empty.")
		return out

	var schema := {
		"schema_version": 1,
		"appid": appid,
		"gamename": str(app.get("gamename", "")),
		"vdf_version": str(app.get("version", "")),
		"groups": [],
		"languages": [],
		"achievements": [],
		"stats": [],
	}
	var languages: Array = []
	var plain_stats := 0
	var bit_keys_seen := {}

	for stat_id in stats.keys():
		var stat: Variant = stats[stat_id]
		if typeof(stat) != TYPE_DICTIONARY:
			continue
		var stat_dict: Dictionary = stat
		if not stat_dict.has("bits"):
			var parsed_stat := _parse_plain_stat(str(stat_id), stat_dict)
			if parsed_stat.is_empty():
				out["warnings"].append("STAT_UNREADABLE: stat \"%s\" has no name or an unknown type, skipped." % str(stat_id))
			else:
				schema["stats"].append(parsed_stat)
			continue
		var group_id := str(stat_id)
		schema["groups"].append({
			"stat_id": group_id,
			"type": str(stat_dict.get("type", "ACHIEVEMENTS")),
		})
		var bits: Dictionary = stat_dict.get("bits", {})
		for bit_key in bits.keys():
			var entry: Variant = bits[bit_key]
			if typeof(entry) != TYPE_DICTIONARY:
				out["warnings"].append("BIT_SKIPPED: bit \"%s\" is not an object." % str(bit_key))
				continue
			var ach_data: Dictionary = entry
			var api_name := str(ach_data.get("name", "")).strip_edges()
			if api_name.is_empty():
				out["warnings"].append("ACH_WITHOUT_NAME: bit \"%s\" has no name, skipped." % str(bit_key))
				continue

			var bit := -1
			if str(bit_key).is_valid_int():
				bit = str(bit_key).to_int()
				# Un bit est unique DANS un groupe : deux groupes distincts
				# numérotent leurs succès chacun à partir de zéro.
				var bit_key_id := "%s:%d" % [group_id, bit]
				if bit_keys_seen.has(bit_key_id):
					out["warnings"].append("BIT_DUPLICATE: bit %d appears twice in group %s, \"%s\" kept anyway." % [bit, group_id, api_name])
				bit_keys_seen[bit_key_id] = true

			var display: Dictionary = {}
			var raw_display: Variant = ach_data.get("display", {})
			if typeof(raw_display) == TYPE_DICTIONARY:
				var names: Dictionary = (raw_display as Dictionary).get("name", {})
				var descs: Dictionary = (raw_display as Dictionary).get("desc", {})
				for lang in names.keys():
					_ensure_lang(display, str(lang))
					display[str(lang)]["name"] = str(names[lang])
					if not languages.has(str(lang)):
						languages.append(str(lang))
				for lang in descs.keys():
					_ensure_lang(display, str(lang))
					display[str(lang)]["desc"] = str(descs[lang])
					if not languages.has(str(lang)):
						languages.append(str(lang))
			else:
				out["warnings"].append("ACH_DISPLAY_MISSING: \"%s\" has no display block." % api_name)

			var hidden := false
			if typeof(raw_display) == TYPE_DICTIONARY:
				hidden = str((raw_display as Dictionary).get("hidden", "0")) == "1"

			var icon_ref := ""
			var icon_gray_ref := ""
			if typeof(raw_display) == TYPE_DICTIONARY:
				icon_ref = str((raw_display as Dictionary).get("icon", ""))
				icon_gray_ref = str((raw_display as Dictionary).get("icon_gray", ""))

			var ach := {
				"api_name": api_name,
				"group": group_id,
				"hidden": hidden,
				"display": display,
				"icon": _resolve_icon(api_name, out["warnings"]),
				"remote_icon": icon_ref,
				"remote_icon_gray": icon_gray_ref,
			}
			if bit >= 0:
				ach["bit"] = bit
			schema["achievements"].append(ach)

	# English d'abord : Steamworks l'exige comme langue de référence. Le reste
	# garde l'ordre de rencontre du fichier, ce qui reproduit exactement l'ordre
	# d'origine à la réexportation (y compris la pseudo-langue « token »).
	var ordered: Array = []
	if languages.has("english"):
		ordered.append("english")
	for lang in languages:
		if str(lang) != "english":
			ordered.append(str(lang))
	schema["languages"] = ordered if not ordered.is_empty() else ["english"]

	var model = SchemaModel.new()
	model.from_dict(schema)
	if not source_path.is_empty():
		model.schema_path = source_path

	out["model"] = model
	out["ok"] = true
	return out


## Une stat ordinaire (INT / FLOAT / AVGRATE) telle que Steamworks l'écrit :
## type, name, display.name, puis maxchange / incrementonly / min / max /
## default / windowsize / permission, chaque option n'apparaissant que si elle
## est définie. Relevé sur un export réel, pas deviné.
static func _parse_plain_stat(stat_id: String, s: Dictionary) -> Dictionary:
	var type := str(s.get("type", "")).to_upper()
	if not ["INT", "FLOAT", "AVGRATE"].has(type):
		return {}
	# Sans `name`, la stat est inutilisable : c'est la clé que le code du jeu
	# appelle. On la refuse plutôt que d'importer une entrée vide.
	if str(s.get("name", "")).strip_edges().is_empty():
		return {}
	var display: Dictionary = {}
	if typeof(s.get("display")) == TYPE_DICTIONARY:
		display = s.get("display")
	return {
		"stat_id": stat_id,
		"api_name": str(s.get("name", "")).strip_edges(),
		"type": type,
		"default": float(s.get("default", 0)),
		"min": float(s.get("min", 0)),
		"max": float(s.get("max", 0)),
		"max_change": float(s.get("maxchange", 0)),
		"increment_only": str(s.get("incrementonly", "0")) == "1",
		"window_size": float(s.get("windowsize", 0.0)),
		"permission": str(s.get("permission", "")),
		"display_name": str(display.get("name", "")),
	}


static func _ensure_lang(display: Dictionary, lang: String) -> void:
	if not display.has(lang):
		display[lang] = {"name": "", "desc": ""}


# --- Résolution des icônes ----------------------------------------------------
## Le VDF ne référence pas un fichier local mais le nom haché que Steam a
## attribué à l'image uploadée. On ne peut donc pas la retrouver par ce nom : on
## cherche une source locale nommée d'après l'API name, et si elle n'existe pas,
## l'achievement garde son hash distant (`remote_icon`) pour que la
## réexportation ne perde rien.
static func _resolve_icon(api_name: String, warnings: Array) -> String:
	var base := api_name.to_lower()
	var candidates := [
		"res://steam/img/%s.jpg" % base,
		"res://steam/img/%s.png" % base,
		"res://steam/icons/%s.png" % base,
		"res://steam/icons/%s.jpg" % base,
	]
	for path in candidates:
		if FileAccess.file_exists(ProjectSettings.globalize_path(path)):
			return path
	warnings.append("ICON_SOURCE_NOT_FOUND: no local source image for \"%s\" (looked for %s). The icon hash from Steam is preserved, so re-exporting is safe." % [api_name, ", ".join(PackedStringArray(candidates))])
	return ""


# --- Parseur ------------------------------------------------------------------

static func _tokenize(text: String) -> Dictionary:
	var tokens: Array = []
	var errors: Array = []
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if c == "\"" or c == "'":
			var quote := c
			var buf := ""
			var closed := false
			i += 1
			while i < n:
				var ch := text[i]
				if ch == "\\" and i + 1 < n:
					var nxt := text[i + 1]
					match nxt:
						"n": buf += "\n"
						"t": buf += "\t"
						"r": buf += "\r"
						"\\": buf += "\\"
						"\"": buf += "\""
						"'": buf += "'"
						_: buf += nxt
					i += 2
					continue
				if ch == quote:
					closed = true
					i += 1
					break
				buf += ch
				i += 1
			if not closed:
				errors.append("UNTERMINATED_STRING: a quoted value never closes (offset %d)." % i)
				return {"ok": false, "tokens": tokens, "errors": errors}
			tokens.append({"t": "str", "v": buf})
		elif c == "{":
			tokens.append({"t": "{"})
			i += 1
		elif c == "}":
			tokens.append({"t": "}"})
			i += 1
		elif c == "/" and i + 1 < n and text[i + 1] == "/":
			while i < n and text[i] != "\n":
				i += 1
		elif c == " " or c == "\t" or c == "\n" or c == "\r":
			i += 1
		else:
			var buf2 := ""
			while i < n:
				var rc := text[i]
				if rc == " " or rc == "\t" or rc == "\n" or rc == "\r" or rc == "{" or rc == "}" or rc == "\"":
					break
				buf2 += rc
				i += 1
			if buf2.is_empty():
				i += 1
				continue
			tokens.append({"t": "str", "v": buf2})
	return {"ok": true, "tokens": tokens, "errors": errors}


static func _parse_object(tokens: Array, open_index: int) -> Dictionary:
	var obj := {}
	var i := open_index + 1
	while i < tokens.size():
		var tok: Dictionary = tokens[i]
		if tok["t"] == "}":
			return {"ok": true, "value": obj, "next": i + 1}
		if tok["t"] != "str":
			return {"ok": false, "error": "STRUCTURE: unexpected \"%s\" where a key was expected (token %d)." % [tok["t"], i]}
		var key: String = tok["v"]
		i += 1
		if i >= tokens.size():
			return {"ok": false, "error": "UNBALANCED_BRACES: file ends after key \"%s\"." % key}
		var value_token: Dictionary = tokens[i]
		if value_token["t"] == "{":
			var sub := _parse_object(tokens, i)
			if not sub["ok"]:
				return sub
			obj[key] = sub["value"]
			i = sub["next"]
		elif value_token["t"] == "str":
			obj[key] = value_token["v"]
			i += 1
		else:
			return {"ok": false, "error": "STRUCTURE: key \"%s\" is followed by \"%s\"." % [key, value_token["t"]]}
	return {"ok": false, "error": "UNBALANCED_BRACES: %d brace(s) never closed." % 1}
