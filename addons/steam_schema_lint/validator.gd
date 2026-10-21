@tool
extends RefCounted
## Règles de validation du schéma, alignées sur les contraintes Steamworks
## vérifiées dans la doc officielle (partner.steamgames.com/doc/features/achievements).
##
## Chaque problème renvoyé est un dictionnaire :
##   { severity = "error" | "warning", code = String, target = String, message = String }
## `error` bloque l'export, `warning` non.

const MIN_ICON_SIZE := 64
const API_NAME_RE := "^[A-Za-z][A-Za-z0-9_]*$"
const VALID_STAT_TYPES := ["INT", "FLOAT", "AVGRATE"]


static func validate(model) -> Array:
	var issues: Array = []

	if str(model.appid).strip_edges().is_empty():
		issues.append(_issue("error", "APPID_MISSING", "", "App ID is empty — the VDF root key is the app ID."))
	elif not _is_digits(str(model.appid)):
		issues.append(_issue("error", "APPID_NOT_NUMERIC", str(model.appid),
			"App ID must be numeric digits only (found \"%s\")." % model.appid))

	for g in model.groups:
		if not _is_digits(str(g.get("stat_id", ""))):
			issues.append(_issue("error", "BITS_STAT_ID_INVALID", str(g.get("stat_id", "")),
				"Group stat ID must be the numeric ID Steamworks assigned to that achievements stat."))

	var seen_names := {}
	var seen_bits := {}
	for ach in model.achievements:
		var api_name := str(ach.get("api_name", ""))
		var target := api_name if not api_name.is_empty() else "<unnamed>"

		if api_name.is_empty():
			issues.append(_issue("error", "API_NAME_EMPTY", target,
				"Achievement has an empty API name."))
		elif not _matches(api_name, API_NAME_RE):
			issues.append(_issue("error", "API_NAME_FORMAT", target,
				"API name \"%s\" must start with a letter and contain only A-Z, a-z, 0-9 and _." % api_name))
		# Pas d'avertissement sur la casse : Steam s'en moque, et un jeu qui
		# nomme ses succès en minuscules en recevrait un par succès. Le vrai
		# risque (code et schéma qui divergent) est couvert par le scan.

		if seen_names.has(api_name) and not api_name.is_empty():
			issues.append(_issue("error", "API_NAME_DUPLICATE", target,
				"API name \"%s\" is used by more than one achievement." % api_name))
		seen_names[api_name] = true

		var bit := int(ach.get("bit", -1))
		# L'unicité d'un bit est locale au groupe : deux groupes numérotent
		# leurs succès chacun à partir de zéro.
		var bit_id := "%s:%d" % [str(ach.get("group", model.default_group())), bit]
		if bit < 0:
			issues.append(_issue("error", "BIT_INVALID", target, "Achievement has no valid bit index."))
		elif bit > 31:
			issues.append(_issue("error", "BIT_OUT_OF_RANGE", target,
				"Bit index %d does not fit: a group is a 32-bit stat (bits 0-31). Move it to another group." % bit))
		elif seen_bits.has(bit_id):
			issues.append(_issue("error", "BIT_DUPLICATE", target,
				"Bit index %d is already taken in group %s — two achievements would collide." % [bit, str(ach.get("group", model.default_group()))]))
		seen_bits[bit_id] = true

		_check_display(model, ach, target, issues)
		_check_icon(ach, target, issues)

	# Les fichiers d'icônes sont nommés en minuscules : « Ach_X » et « ACH_X »
	# écriraient le même fichier, et l'un des deux perdrait son image.
	var lower_names := {}
	for ach in model.achievements:
		var lname := str(ach.get("api_name", "")).to_lower()
		if lname.is_empty() or not str(ach.get("remote_icon", "")).is_empty():
			continue
		if lower_names.has(lname) and lower_names[lname] != str(ach.get("api_name", "")):
			issues.append(_issue("warning", "ICON_FILE_COLLISION", str(ach.get("api_name", "")),
				"\"%s\" and \"%s\" differ only by case: their icon files would overwrite each other." % [lower_names[lname], ach.get("api_name", "")]))
		lower_names[lname] = str(ach.get("api_name", ""))

	var seen_stats := {}
	for st in model.stats:
		var api_name := str(st.get("api_name", ""))
		var target := api_name if not api_name.is_empty() else "<unnamed stat>"

		if not VALID_STAT_TYPES.has(str(st.get("type", ""))):
			issues.append(_issue("error", "STAT_TYPE_INVALID", target,
				"Stat type \"%s\" is not one of INT, FLOAT, AVGRATE." % str(st.get("type", ""))))
		if api_name.is_empty():
			issues.append(_issue("error", "STAT_API_NAME_EMPTY", target, "Stat has an empty API name."))
		elif not _matches(api_name, API_NAME_RE):
			issues.append(_issue("error", "STAT_API_NAME_FORMAT", target,
				"Stat API name \"%s\" must start with a letter and contain only A-Z, a-z, 0-9 and _." % api_name))
		elif seen_stats.has(api_name):
			issues.append(_issue("error", "STAT_API_NAME_DUPLICATE", target,
				"Stat API name \"%s\" is used twice." % api_name))
		seen_stats[api_name] = true
		if not api_name.is_empty() and seen_names.has(api_name):
			issues.append(_issue("warning", "STAT_NAME_MATCHES_ACHIEVEMENT", target,
				"\"%s\" is both a stat and an achievement name — easy to call the wrong Steam function." % api_name))

		var lo := float(st.get("min", 0))
		var hi := float(st.get("max", 0))
		if hi != 0.0 and hi < lo:
			issues.append(_issue("error", "STAT_MAX_BELOW_MIN", target,
				"Max value (%s) is below min value (%s)." % [hi, lo]))
		# Sans plafond, la stat est écrite avec « max 0 » et Steam refuse la
		# valeur : le validateur laissait passer le cas.
		if hi == 0.0 and lo == 0.0:
			issues.append(_issue("warning", "STAT_MAX_UNSET", target,
				"No max value set: the stat is exported with max 0 and Steam will not store anything. Set a ceiling."))
		if str(st.get("type", "")) == "AVGRATE" and float(st.get("window_size", 0.0)) <= 0.0:
			issues.append(_issue("warning", "STAT_WINDOW_MISSING", target,
				"AVGRATE stat has no average window — Steam will use its default, which is rarely what you want."))
		if str(st.get("display_name", "")).strip_edges().is_empty():
			issues.append(_issue("warning", "STAT_DISPLAY_NAME_EMPTY", target,
				"No display name: the stat will look empty on the player's Steam profile."))
		# `aggregated` est conservé dans le schéma mais n'est PAS écrit dans le
		# VDF : la clé exacte n'a jamais été vue dans un export réel, et ce
		# projet n'écrit pas de format deviné. On le dit plutôt que de laisser
		# croire que la case fait quelque chose.
		if bool(st.get("aggregated", false)):
			issues.append(_issue("warning", "STAT_AGGREGATED_NOT_EXPORTED", target,
				"Marked aggregated, but this flag is stored and not written: the VDF key has not been verified against a real export. Tick it in App Admin instead."))

	# Groupes et stats partagent les clés numériques du bloc stats du VDF.
	var seen_ids := {}
	for g in model.groups:
		seen_ids[str(g.get("stat_id", ""))] = "group"
	for st in model.stats:
		var sid := str(st.get("stat_id", ""))
		if sid.is_empty():
			continue
		if seen_ids.has(sid):
			issues.append(_issue("error", "STAT_ID_DUPLICATE", str(st.get("api_name", "")),
				"Stat ID %s is already used by another %s — the VDF would keep only one of them." % [sid, seen_ids[sid]]))
		seen_ids[sid] = "stat"

	return issues


static func errors_only(issues: Array) -> Array:
	return issues.filter(func(i): return i["severity"] == "error")


# --- Contrôles unitaires ------------------------------------------------------

static func _check_display(model, ach: Dictionary, target: String, issues: Array) -> void:
	var display: Dictionary = ach.get("display", {})
	var english: Dictionary = display.get("english", {})
	if str(display.get("english", {}).get("name", "")).strip_edges().is_empty():
		issues.append(_issue("error", "ACH_DISPLAY_NAME_EN_MISSING", target,
			"English display name is required — Steamworks needs it even for a single-language game."))
	if str(english.get("desc", "")).strip_edges().is_empty():
		issues.append(_issue("error", "ACH_DISPLAY_DESC_EN_MISSING", target,
			"English description is missing."))
	for lang in model.languages:
		if str(lang) == "english":
			continue
		var entry: Dictionary = display.get(lang, {})
		var lang_name := str(entry.get("name", "")).strip_edges()
		var lang_desc := str(entry.get("desc", "")).strip_edges()
		if lang_name.is_empty() and lang_desc.is_empty():
			issues.append(_issue("warning", "ACH_LANG_MISSING", target,
				"No text for declared language \"%s\" — it will be omitted from the VDF." % lang))


static func _check_icon(ach: Dictionary, target: String, issues: Array) -> void:
	# Une icône déjà uploadée sur Steam (hash présent) n'a rien à vérifier
	# localement : elle vit dans le back-end, pas dans le projet.
	if not str(ach.get("remote_icon", "")).is_empty():
		return
	var icon := str(ach.get("icon", ""))
	if icon.strip_edges().is_empty():
		issues.append(_issue("error", "ICON_MISSING", target, "No icon source set."))
		return
	var abs_path := ProjectSettings.globalize_path(icon)
	if not FileAccess.file_exists(abs_path):
		issues.append(_issue("error", "ICON_NOT_FOUND", target, "Icon file does not exist: %s" % icon))
		return
	var dims := _icon_dimensions(abs_path)
	if dims.x <= 0:
		issues.append(_issue("error", "ICON_UNREADABLE", target, "Icon is not a readable image: %s" % icon))
		return
	if dims.x != dims.y:
		issues.append(_issue("error", "ICON_NOT_SQUARE", target,
			"Icon is %dx%d — Steamworks requires a square image." % [dims.x, dims.y]))
	if mini(dims.x, dims.y) < MIN_ICON_SIZE:
		issues.append(_issue("error", "ICON_TOO_SMALL", target,
			"Icon is %dpx — %dpx is the minimum size." % [mini(dims.x, dims.y), MIN_ICON_SIZE]))


## Dimensions d'une image, mémorisées par chemin et date de modification.
## `validate()` tourne à chaque frappe dans la recherche du dock : recharger
## vingt PNG à chaque caractère coûtait 20 ms sur la démo, bien plus sur un vrai
## projet.
static var _icon_sizes := {}


static func _icon_dimensions(abs_path: String) -> Vector2i:
	var key := abs_path + "|" + str(FileAccess.get_modified_time(abs_path))
	if _icon_sizes.has(key):
		return _icon_sizes[key]
	var img := Image.load_from_file(abs_path)
	var dims := Vector2i.ZERO if img == null else Vector2i(img.get_width(), img.get_height())
	_icon_sizes[key] = dims
	return dims


static func _issue(severity: String, code: String, target: String, message: String) -> Dictionary:
	return {"severity": severity, "code": code, "target": target, "message": message}


static func _is_digits(s: String) -> bool:
	return s.is_valid_int() and s.to_int() >= 0


static func _matches(value: String, pattern: String) -> bool:
	var re := RegEx.create_from_string(pattern)
	return re.search(value) != null
