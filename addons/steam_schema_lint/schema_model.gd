@tool
extends RefCounted
## Steam Achievements Studio — modèle de données du schéma Steamworks.
##
## Un seul fichier, versionné dans le dépôt du jeu, sert de source de vérité :
## `res://steam/steam_schema.json`. Lisible et diffable à la main, ce qui rend le
## palier gratuit utilisable sans interface.
##
## Le format de référence n'est plus une reconstitution : c'est un export réel de
## Steamworks (`tests/fixtures/gambit_loop_raw.txt`, app 4531320, 50 achievements).
## Trois choses en sont sorties, fausses dans la première version :
##
##   1. les achievements sont rangés en **groupes** : chaque groupe est une stat
##      de type « ACHIEVEMENTS », avec son identifiant numérique et sa propre
##      numérotation de bits ;
##   2. les icônes sont référencées par un **nom de fichier haché** attribué par
##      Steam à l'upload, jamais par un chemin `/img/...` ;
##   3. la casse des API names est significative (`ach_first_blood` chez ce jeu).
##
## Invariants :
##   - un index de bit n'est jamais recyclé ni renuméroté. L'export réel montre
##     des trous (groupe 2 : 0-11, puis 14-18, puis 26) : Steam les tolère, il ne
##     tolère pas un décalage des succès déjà débloqués par les joueurs ;
##   - tout ce qu'on ne sait pas régénérer est préservé : le hash d'icône vient de
##     Steam, on le garde au lieu de l'écraser.

const SCHEMA_VERSION := 1
const DEFAULT_SCHEMA_PATH := "res://steam/steam_schema.json"
const VALID_STAT_TYPES := ["INT", "FLOAT", "AVGRATE"]
const ACHIEVEMENT_STAT_TYPE := "ACHIEVEMENTS"
## Un groupe est une stat Steam de 32 bits : un bit par succès, donc 0 à 31.
const MAX_BIT := 31

var appid := ""
var gamename := ""
var vdf_version := ""
## [{ "stat_id": "1", "type": "ACHIEVEMENTS" }, ...]
var groups: Array = []
var languages: Array = ["english"]
var achievements: Array = []
var stats: Array = []
var schema_path := DEFAULT_SCHEMA_PATH
var last_error := ""


func load_file(path: String) -> bool:
	last_error = ""
	if not FileAccess.file_exists(path):
		last_error = "Schema file not found: %s" % path
		return false
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		last_error = "Schema file is empty or unreadable: %s" % path
		return false
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "Schema is not a JSON object: %s" % path
		return false
	from_dict(parsed)
	schema_path = path
	return true


func from_dict(data: Dictionary) -> void:
	appid = str(data.get("appid", ""))
	gamename = str(data.get("gamename", ""))
	vdf_version = str(data.get("vdf_version", ""))
	languages = (data.get("languages", ["english"]) as Array).duplicate(true)

	groups = []
	for raw in data.get("groups", []):
		if typeof(raw) == TYPE_DICTIONARY:
			groups.append({
				"stat_id": str((raw as Dictionary).get("stat_id", "1")),
				"type": str((raw as Dictionary).get("type", ACHIEVEMENT_STAT_TYPE)),
				# Plus haut bit jamais attribué. Absent des schémas antérieurs : il est
				# alors reconstruit depuis les succès présents, plus bas.
				"max_bit": int((raw as Dictionary).get("max_bit", -1)),
			})
	if groups.is_empty():
		groups.append({
			"stat_id": str(data.get("achievement_bits_stat_id", "1")),
			"type": ACHIEVEMENT_STAT_TYPE,
			"max_bit": -1,
		})

	achievements = []
	for raw in data.get("achievements", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var ach: Dictionary = (raw as Dictionary).duplicate(true)
		# Les API names sont sensibles à la casse : on les préserve tels quels.
		ach["api_name"] = str(ach.get("api_name", "")).strip_edges()
		ach["group"] = str(ach.get("group", default_group()))
		if not has_group(ach["group"]):
			groups.append({"stat_id": ach["group"], "type": ACHIEVEMENT_STAT_TYPE})
		for key in ["icon", "remote_icon", "remote_icon_gray"]:
			ach[key] = str(ach.get(key, ""))
		if not ach.has("bit"):
			ach["bit"] = next_bit(achievements, ach["group"])
		ach["bit"] = int(ach["bit"])
		_mark_bit_used(ach["group"], ach["bit"])
		ach["hidden"] = bool(ach.get("hidden", false))
		if typeof(ach.get("display")) != TYPE_DICTIONARY:
			ach["display"] = {}
		achievements.append(ach)

	stats = []
	for raw in data.get("stats", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = (raw as Dictionary).duplicate(true)
		st["api_name"] = str(st.get("api_name", "")).strip_edges()
		st["type"] = str(st.get("type", "INT")).to_upper()
		st["permission"] = str(st.get("permission", ""))
		coerce_stat_numbers(st)
		stats.append(st)


func to_dict() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"appid": appid,
		"gamename": gamename,
		"vdf_version": vdf_version,
		"groups": groups,
		"languages": languages,
		"achievements": achievements,
		"stats": stats,
	}


func save_file(path := "") -> bool:
	last_error = ""
	var target := path if not path.is_empty() else schema_path
	var dir := target.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			last_error = "Cannot create directory %s (error %d)" % [dir, err]
			return false
	# Écrire à côté puis renommer : une coupure au milieu de l'écriture laisserait
	# sinon un schéma tronqué, et c'est la seule copie de l'utilisateur.
	var tmp := target + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		last_error = "Cannot write %s (error %d)" % [tmp, FileAccess.get_open_error()]
		return false
	f.store_string(JSON.stringify(to_dict(), "	", false) + "\n")
	f.close()
	var err := DirAccess.rename_absolute(tmp, target)
	if err != OK:
		last_error = "Cannot replace %s (error %d)" % [target, err]
		return false
	schema_path = target
	return true


# --- Groupes ------------------------------------------------------------------

func has_group(stat_id: String) -> bool:
	for g in groups:
		if str(g["stat_id"]) == stat_id:
			return true
	return false


func group_type(stat_id: String) -> String:
	for g in groups:
		if str(g["stat_id"]) == stat_id:
			return str(g["type"])
	return ACHIEVEMENT_STAT_TYPE


func default_group() -> String:
	return str(groups[0]["stat_id"]) if not groups.is_empty() else "1"


## Premier groupe qui a encore un bit libre ; s'il n'y en a aucun, un nouveau
## groupe est créé avec le prochain identifiant de stat libre.
func group_with_room() -> String:
	if groups.is_empty():
		groups.append({"stat_id": default_group(), "type": ACHIEVEMENT_STAT_TYPE})
	for g in groups:
		var sid := str(g["stat_id"])
		if next_bit(achievements, sid) <= MAX_BIT:
			return sid
	var sid := next_free_stat_id()
	groups.append({"stat_id": sid, "type": ACHIEVEMENT_STAT_TYPE})
	return sid


## Identifiant numérique libre, commun aux groupes ET aux stats : dans le VDF,
## les deux sont des clés du même bloc, un doublon écraserait l'un des deux.
func next_free_stat_id() -> String:
	var max_id := 0
	for g in groups:
		var gid := str(g.get("stat_id", ""))
		if gid.is_valid_int():
			max_id = maxi(max_id, int(gid))
	for st in stats:
		var sid := str(st.get("stat_id", ""))
		if sid.is_valid_int():
			max_id = maxi(max_id, int(sid))
	return str(max_id + 1)


# --- Achievements -------------------------------------------------------------

func find_achievement(api_name: String) -> Dictionary:
	for ach in achievements:
		if str(ach.get("api_name", "")) == api_name:
			return ach
	return {}


func add_achievement(api_name: String, group := "") -> Dictionary:
	var name := normalize_api_name(api_name)
	if name.is_empty():
		name = "ACH_NEW"
	var candidate := name
	var i := 2
	while not find_achievement(candidate).is_empty():
		candidate = "%s_%d" % [name, i]
		i += 1
	var target_group := group if not group.is_empty() else default_group()
	# Groupe plein (32 succès) : on prend le premier qui a de la place, sinon on
	# en ouvre un. Continuer à compter au-delà de 31 donnait un bit que Steam ne
	# peut pas stocker.
	if next_bit(achievements, target_group) > MAX_BIT:
		target_group = group_with_room()
	var ach := {
		"api_name": candidate,
		"group": target_group,
		"bit": next_bit(achievements, target_group),
		"hidden": false,
		"icon": "",
		"remote_icon": "",
		"remote_icon_gray": "",
		"display": {},
	}
	_mark_bit_used(target_group, ach["bit"])
	for lang in languages:
		ach["display"][lang] = {"name": "", "desc": ""}
	achievements.append(ach)
	return ach


func remove_achievement(api_name: String) -> bool:
	for i in achievements.size():
		if str(achievements[i].get("api_name", "")) == api_name:
			achievements.remove_at(i)
			return true
	return false


## Index de bit suivant DANS UN GROUPE, jamais recyclé : maximum existant + 1.
func next_bit(from_list: Array = [], group := "") -> int:
	var pool: Array = from_list if not from_list.is_empty() else achievements
	# Un bit libéré par une suppression ne doit jamais être réattribué : le joueur
	# qui avait débloqué l'ancien succès verrait le nouveau déjà débloqué. On part
	# donc du plus haut bit déjà attribué au groupe, pas des bits encore occupés.
	var max_bit := _group_max_bit(group)
	for entry in pool:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var ach: Dictionary = entry
		if not group.is_empty() and str(ach.get("group", "")) != group:
			continue
		max_bit = maxi(max_bit, int(ach.get("bit", -1)))
	return max_bit + 1


func _group_max_bit(stat_id: String) -> int:
	if stat_id.is_empty():
		return -1
	for g in groups:
		if str(g.get("stat_id", "")) == stat_id:
			return int(g.get("max_bit", -1))
	return -1


func _mark_bit_used(stat_id: String, bit: int) -> void:
	if stat_id.is_empty():
		return
	for g in groups:
		if str(g.get("stat_id", "")) == stat_id:
			if int(g.get("max_bit", -1)) < bit:
				g["max_bit"] = bit
			return
	# `default_group()` renvoie « 1 » sans l'inscrire : le premier succès créé sur
	# un modèle neuf doit donc créer l'entrée, sinon la mémoire du bit est perdue.
	groups.append({"stat_id": stat_id, "type": ACHIEVEMENT_STAT_TYPE, "max_bit": bit})


# --- Stats --------------------------------------------------------------------

func find_stat(api_name: String) -> Dictionary:
	for st in stats:
		if str(st.get("api_name", "")) == api_name:
			return st
	return {}


func add_stat(api_name: String, type := "INT") -> Dictionary:
	var name := normalize_api_name(api_name)
	if name.is_empty():
		name = "STAT_NEW"
	var candidate := name
	var i := 2
	while not find_stat(candidate).is_empty():
		candidate = "%s_%d" % [name, i]
		i += 1
	var st := {
		"api_name": candidate,
		"type": type.to_upper() if VALID_STAT_TYPES.has(type.to_upper()) else "INT",
		"default": 0,
		"min": 0,
		"max": 0,
		"increment_only": false,
		"max_change": 0,
		"window_size": 0.0,
		"permission": "",
		"aggregated": false,
		"display_name": "",
	}
	stats.append(st)
	return st


# --- Utilitaires --------------------------------------------------------------

## Normalise un nom d'API : MAJUSCULES, chiffres et soulignés. Ne s'applique
## QU'AUX noms neufs saisis dans le dock, jamais à ce qui vient d'un fichier.
static func normalize_api_name(raw: String) -> String:
	var re := RegEx.create_from_string("[^A-Za-z0-9_]+")
	var out := re.sub(raw.strip_edges(), "_", true).to_upper()
	var multi := RegEx.create_from_string("_+")
	out = multi.sub(out, "_", true)
	while out.begins_with("_"):
		out = out.substr(1)
	while out.ends_with("_"):
		out = out.substr(0, out.length() - 1)
	return out


## Le parseur JSON de Godot renvoie des flottants pour tous les nombres : sans
## ce passage, une stat INT relue depuis le fichier s'écrirait « 0.0 ».
static func coerce_stat_numbers(st: Dictionary) -> void:
	var is_int := str(st.get("type", "")) == "INT"
	for key in ["default", "min", "max", "max_change"]:
		if not st.has(key):
			continue
		st[key] = int(st[key]) if is_int else float(st[key])
	# La fenêtre n'existe que pour AVGRATE, et c'est toujours un flottant.
	if st.has("window_size"):
		st["window_size"] = float(st["window_size"])
