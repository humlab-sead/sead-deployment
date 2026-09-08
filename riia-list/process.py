#!/usr/bin/env python3
"""
Process riia-list/list.csv: infer species from Swedish archaeological terms,
match against SEAD database tables, and write output.csv.
"""
import csv
import psycopg2
import sys

# Database connection
conn = psycopg2.connect(
    host="localhost",
    port=5432,
    dbname="sead_staging",
    user="sead_ro",
    password="00q2jyrNVSZqeQzK",
)
cur = conn.cursor()

# --- Load all Swedish common names ---
cur.execute("""
    SELECT taxon_common_name_id, taxon_id, common_name FROM tbl_taxa_common_names WHERE language_id = 2
""")
# Build lookup: common_name_lower -> (taxon_common_name_id, taxon_id, common_name)
swedish_common = {}
for tcn_id, taxon_id, cn in cur.fetchall():
    swedish_common[cn.strip().lower()] = (tcn_id, taxon_id, cn.strip())

# --- Load all species with full chain ---
cur.execute("""
    SELECT ttm.taxon_id, ttm.species, ttg.genus_id, ttg.genus_name,
           ttf.family_id, ttf.family_name, tto.order_id, tto.order_name
    FROM tbl_taxa_tree_master ttm
    JOIN tbl_taxa_tree_genera ttg ON ttm.genus_id = ttg.genus_id
    JOIN tbl_taxa_tree_families ttf ON ttg.family_id = ttf.family_id
    JOIN tbl_taxa_tree_orders tto ON ttf.order_id = tto.order_id
""")
# Build lookup: "genus species" lower -> record
species_lookup = {}
for row in cur.fetchall():
    key = f"{row[3]} {row[1]}".strip().lower()
    species_lookup[key] = row

# --- Load all genera ---
cur.execute("SELECT genus_id, genus_name, family_id FROM tbl_taxa_tree_genera")
genera_lookup = {}
for row in cur.fetchall():
    genera_lookup[row[1].strip().lower()] = row

# --- Load all families ---
cur.execute("SELECT family_id, family_name, order_id FROM tbl_taxa_tree_families")
families_lookup = {}
for row in cur.fetchall():
    families_lookup[row[1].strip().lower()] = row

# --- Load all orders ---
cur.execute("SELECT order_id, order_name FROM tbl_taxa_tree_orders")
orders_lookup = {}
for row in cur.fetchall():
    orders_lookup[row[1].strip().lower()] = row


def find_common_name_match(common_name):
    """Find exact Swedish common name match. Returns (matched_name, taxon_common_name_id) or ('', '')."""
    if not common_name:
        return ('', '')
    nl = common_name.strip().lower()
    # Exact match
    if nl in swedish_common:
        tcn_id, taxon_id, cn = swedish_common[nl]
        return (cn, tcn_id)
    # No fuzzy matching - only exact
    return ('', '')


def find_species_match(species_name, genus_name=None):
    """Find species match. Returns (matched_full_name, taxon_id, full_chain) or ('', '', None)."""
    if not species_name:
        return ('', '', None)
    sl = species_name.strip().lower()
    if genus_name:
        full = f"{genus_name.strip().lower()} {sl}"
        if full in species_lookup:
            rec = species_lookup[full]
            return (f"{rec[3]} {rec[1]}", rec[0], rec)
    # Try without genus - search all species
    for key, rec in species_lookup.items():
        sp_part = rec[1].strip().lower()
        if sl == sp_part or sl == key:
            return (f"{rec[3]} {rec[1]}", rec[0], rec)
    return ('', '', None)


def find_genus_match(genus_name):
    """Find genus match. Returns (matched_genus, genus_id, family_id) or ('', '', '')."""
    if not genus_name:
        return ('', '', '')
    gl = genus_name.strip().lower()
    if gl in genera_lookup:
        rec = genera_lookup[gl]
        return (rec[1], rec[0], rec[2])
    return ('', '', '')


def find_family_match(family_name):
    """Find family match. Returns (matched_family, family_id, order_id) or ('', '', '')."""
    if not family_name:
        return ('', '', '')
    fl = family_name.strip().lower()
    if fl in families_lookup:
        rec = families_lookup[fl]
        return (rec[1], rec[0], rec[1])
    return ('', '', '')


def find_order_match(order_name):
    """Find order match. Returns (matched_order, order_id) or ('', '')."""
    if not order_name:
        return ('', '')
    ol = order_name.strip().lower()
    if ol in orders_lookup:
        rec = orders_lookup[ol]
        return (rec[1], rec[0])
    return ('', '')


# --- SPECIES INFERENCE MAPPING ---
# Format: (inferred_meaning, common_name, species, genus, family, order)
INFERENCE = {
    # === FISH ===
    "Aborrskinn": ("Aborre (skinn)", "Aborre", "trutta morio", "Salmo", "Salmonidae", "Salmoniformes"),
    "Agn": ("Agn (fisk)", "Agn", "eperlanus", "Osmerus", "Osmeridae", "Osmeriformes"),
    "Gädda": ("Gädda", "Gädda", "lucius", "Esox", "Esocidae", "Esociformes"),
    "Mört": ("Mört", "Mört", "fluviatilis", "Perca", "Percidae", "Perciformes"),
    "Sik": ("Sik", "Sik", "lavaretus", "Coregonus", "Salmonidae", "Salmoniformes"),
    "Torsk": ("Torsk", "Torsk", "morhua", "Gadus", "Gadidae", "Gadiformes"),
    "Fisk": ("Fisk (generellt)", "Fisk", "", "", "", ""),
    "Fiskben": ("Fiskben", "Fisk", "", "", "", ""),
    "Fiskfjäll": ("Fiskfjäll", "Fisk", "", "", "", ""),
    "Delfin": ("Delfin", "Delfin", "", "", "Delphinidae", "Cetacea"),

    # === TREES - Alder ===
    "Al": ("Al", "Al", "", "Alnus", "Betulaceae", "Fagales"),
    "Albark": ("Albark", "Al", "", "Alnus", "Betulaceae", "Fagales"),
    "Alknopp": ("Alknopp", "Al", "", "Alnus", "Betulaceae", "Fagales"),
    "Alkottar": ("Alkottar", "Al", "", "Alnus", "Betulaceae", "Fagales"),
    "Alkotte": ("Alkotte", "Al", "", "Alnus", "Betulaceae", "Fagales"),

    # === Elm ===
    "Alm": ("Alm", "Alm", "", "Ulmus", "Ulmaceae", "Rosales"),

    # === Ash ===
    "Ask": ("Ask", "Ask", "", "Fraxinus", "Oleaceae", "Lamiales"),
    "Askl": ("Asklöv", "Ask", "", "Fraxinus", "Oleaceae", "Lamiales"),

    # === Aspen ===
    "Asp": ("Asp", "Asp", "", "Populus", "Salicaceae", "Malpighiales"),

    # === Birch ===
    "Björknäver": ("Björknäver", "Björk", "", "Betula", "Betulaceae", "Fagales"),
    "Björkl": ("Björklöv", "Björk", "", "Betula", "Betulaceae", "Fagales"),
    "Bjrök": ("Björk", "Björk", "", "Betula", "Betulaceae", "Fagales"),
    "Betula": ("Björk", "Björk", "", "Betula", "Betulaceae", "Fagales"),

    # === Oak ===
    "Ek": ("Ek", "Ek", "", "Quercus", "Fagaceae", "Fagales"),
    "Ekbark": ("Ekbark", "Ek", "", "Quercus", "Fagaceae", "Fagales"),
    "Ekl": ("Eklöv", "Ek", "", "Quercus", "Fagaceae", "Fagales"),
    "Ekollon": ("Ekollon", "Ek", "", "Quercus", "Fagaceae", "Fagales"),

    # === Beech ===
    "Bok": ("Bok (träd)", "Bok", "", "Fagus", "Fagaceae", "Fagales"),
    "Avenbok": ("Avenbok", "Bok", "", "Fagus", "Fagaceae", "Fagales"),

    # === Pine (Furu) ===
    "Furu": ("Furu", "Furu", "", "Pinus", "Pinaceae", "Pinales"),

    # === Spruce ===
    "Gran": ("Gran", "Gran", "", "Picea", "Pinaceae", "Pinales"),
    "Granbar": ("Granbarr", "Gran", "", "Picea", "Pinaceae", "Pinales"),
    "Granbarr": ("Granbarr", "Gran", "", "Picea", "Pinaceae", "Pinales"),
    "granbarr": ("Granbarr", "Gran", "", "Picea", "Pinaceae", "Pinales"),

    # === Fir ===
    "Idegran": ("Idegran", "Idegran", "", "Abies", "Pinaceae", "Pinales"),

    # === Pine (Tall) ===
    "Tall": ("Tall", "Tall", "", "Pinus", "Pinaceae", "Pinales"),
    "Tallbark": ("Tallbark", "Tall", "", "Pinus", "Pinaceae", "Pinales"),
    "Tallbarr": ("Tallbarr", "Tall", "", "Pinus", "Pinaceae", "Pinales"),
    "Tallkotte": ("Tallkotte", "Tall", "", "Pinus", "Pinaceae", "Pinales"),
    "Tallkottefjäll": ("Tallkottefjäll", "Tall", "", "Pinus", "Pinaceae", "Pinales"),
    "Talll": ("Talllöv", "Tall", "", "Pinus", "Pinaceae", "Pinales"),

    # === Coniferous general ===
    "Barr": ("Barr (generellt)", "Barr", "", "", "Pinaceae", "Pinales"),
    "Barrträd": ("Barrträd", "Barrträd", "", "", "Pinaceae", "Pinales"),
    "Blandmaterial": ("Blandmaterial", "Blandmaterial", "", "", "", ""),

    # === Willow ===
    "Sälg": ("Sälg", "Sälg", "", "Salix", "Salicaceae", "Malpighiales"),

    # === Hazel ===
    "Hasel": ("Hasel", "Hasel", "", "Corylus", "Betulaceae", "Fagales"),
    "Hassel": ("Hassel", "Hassel", "", "Corylus", "Betulaceae", "Fagales"),
    "Hasselnöt": ("Hasselnöt", "Hassel", "", "Corylus", "Betulaceae", "Fagales"),
    "Hasselskal": ("Hasselskal", "Hassel", "", "Corylus", "Betulaceae", "Fagales"),
    "hasselnöt": ("Hasselnöt", "Hassel", "", "Corylus", "Betulaceae", "Fagales"),

    # === Linden ===
    "Lind": ("Lind", "Lind", "", "Tilia", "Malvaceae", "Malvales"),
    "Lindbast": ("Lindbast", "Lind", "", "Tilia", "Malvaceae", "Malvales"),

    # === Maple ===
    "Lönn": ("Lönn", "Lönn", "", "Acer", "Sapindaceae", "Sapindales"),

    # === Rowan ===
    "Rönn": ("Rönn", "Rönn", "", "Sorbus", "Rosaceae", "Rosales"),

    # === Elder ===
    "Fläder": ("Fläder", "Fläder", "", "Sambucus", "Adoxaceae", "Dipsacales"),

    # === Juniper ===
    "En": ("En", "En", "", "Juniperus", "Cupressaceae", "Pinales"),
    "Enbär": ("Enbär", "En", "", "Juniperus", "Cupressaceae", "Pinales"),

    # === Hawthorn ===
    "Hagtorn": ("Hagtorn", "Hagtorn", "", "Crataegus", "Rosaceae", "Rosales"),

    # === Hagg ===
    "Hägg": ("Hägg", "Hägg", "", "Corylus", "Betulaceae", "Fagales"),

    # === Cornus ===
    "Kornell": ("Kornell", "Kornell", "", "Cornus", "Cornaceae", "Cornales"),
    "Skogskornell": ("Skogskornell", "Skogskornell", "", "Cornus", "Cornaceae", "Cornales"),

    # === Syska ===
    "Syska": ("Syska", "Syska", "", "Sorbus", "Rosaceae", "Rosales"),

    # === Larch ===
    "Jlvträd": ("Lövträd", "Lövträd", "", "", "", ""),
    "Löbträd": ("Lövträd", "Lövträd", "", "", "", ""),
    "Lövträ": ("Lövträd", "Lövträd", "", "", "", ""),
    "Lövträd": ("Lövträd", "Lövträd", "", "", "", ""),

    # === ANIMALS - Bear ===
    "Björn": ("Björn", "Björn", "", "Ursus", "Ursidae", "Carnivora"),

    # === Beaver ===
    "Bäver": ("Bäver", "Bäver", "", "Castor", "Castoridae", "Rodentia"),

    # === Bird ===
    "Fågel": ("Fågel", "Fågel", "", "", "", "Aves"),
    "Fågelbär": ("Fågelbär", "Fågelbär", "", "", "", ""),

    # === Sheep ===
    "Får": ("Får", "Får", "", "Ovis", "Bovidae", "Artiodactyla"),
    "Fårlort": ("Fårlort", "Får", "", "Ovis", "Bovidae", "Artiodactyla"),
    "Fårtand": ("Fårtand", "Får", "", "Ovis", "Bovidae", "Artiodactyla"),
    "Lamm": ("Lamm", "Får", "", "Ovis", "Bovidae", "Artiodactyla"),

    # === Goat ===
    "Get": ("Get", "Get", "", "Capra", "Bovidae", "Artiodactyla"),
    "Getapel": ("Getäpple", "Get", "", "Capra", "Bovidae", "Artiodactyla"),

    # === Rodent ===
    "Gnagare": ("Gnagare", "Gnagare", "", "", "", "Rodentia"),

    # === Pig ===
    "Gris": ("Gris", "Gris", "", "Sus", "Suidae", "Artiodactyla"),
    "Svin": ("Svin", "Svin", "", "Sus", "Suidae", "Artiodactyla"),
    "Tamsvin": ("Tamsvin", "Svin", "", "scrofa domesticus", "Sus", "Suidae", "Artiodactyla"),
    "Vildsvin": ("Vildsvin", "Vildsvin", "", "scrofa", "Sus", "Suidae", "Artiodactyla"),
    "Svinbete": ("Svinbete", "Svin", "", "Sus", "Suidae", "Artiodactyla"),

    # === Seal ===
    "Gråsäl": ("Gråsäl", "Gråsäl", "", "groenlandicus", "Halichoerus", "Phocidae", "Carnivora"),
    "Grönlandssäl": ("Grönlandssäl", "Grönlandssäl", "", "greenlandicus", "Pagophilus", "Phocidae", "Carnivora"),
    "Säl": ("Säl", "Säl", "", "", "Phocidae", "Carnivora"),
    "Vikaresäl": ("Vikaresäl", "Vikaresäl", "", "sibirica", "Pusa", "Phocidae", "Carnivora"),

    # === Herbivore ===
    "Gräsätare": ("Gräsätare", "Gräsätare", "", "", "", ""),
    "gräsätare": ("Gräsätare", "Gräsätare", "", "", "", ""),
    "Idisslare": ("Idisslare", "Idisslare", "", "", "", ""),

    # === Deer ===
    "Hjort": ("Hjort", "Hjort", "", "elaphus", "Cervus", "Cervidae", "Artiodactyla"),
    "Hjortdjur": ("Hjortdjur", "Hjortdjur", "", "", "Cervidae", "Artiodactyla"),
    "Hjorthår": ("Hjorthår", "Hjort", "", "Cervus", "Cervidae", "Artiodactyla"),
    "Kronhjort": ("Kronhjort", "Kronhjort", "", "elaphus", "Cervus", "Cervidae", "Artiodactyla"),
    "Rådjur": ("Rådjur", "Rådjur", "", "capreolus", "Capreolus", "Cervidae", "Artiodactyla"),

    # === Moose ===
    "Älg": ("Älg", "Älg", "", "alces", "Alces", "Cervidae", "Artiodactyla"),

    # === Reindeer ===
    "Ren": ("Ren", "Ren", "", "tarandus", "Rangifer", "Cervidae", "Artiodactyla"),
    "Renhår": ("Renhår", "Ren", "", "tarandus", "Rangifer", "Cervidae", "Artiodactyla"),

    # === Fox ===
    "Räv": ("Räv", "Räv", "", "vulpes", "Vulpes", "Canidae", "Carnivora"),

    # === Dog ===
    "Hund": ("Hund", "Hund", "", "lupus familiaris", "Canis", "Canidae", "Carnivora"),

    # === Cat ===
    "Katt": ("Katt", "Katt", "", "catus", "Felis", "Felidae", "Carnivora"),

    # === Horse ===
    "Häst": ("Häst", "Häst", "", "caballus", "Equus", "Equidae", "Perissodactyla"),
    "Hästspillning": ("Hästspillning", "Häst", "", "Equus", "Equidae", "Perissodactyla"),
    "Hästtand": ("Hästtand", "Häst", "", "Equus", "Equidae", "Perissodactyla"),
    "Hästsko": ("Hästsko", "Hästsko", "", "", "", ""),

    # === Hen ===
    "Höna": ("Höna", "Höna", "", "gallus", "Gallus", "Phasianidae", "Galliformes"),

    # === Cow/Cattle ===
    "Ko": ("Ko", "Nötkreatur", "", "taurus", "Bos", "Bovidae", "Artiodactyla"),
    "Kalv": ("Kalv", "Nötkreatur", "", "taurus", "Bos", "Bovidae", "Artiodactyla"),
    "nötkreatur": ("Nötkreatur", "Nötkreatur", "", "Bos", "Bovidae", "Artiodactyla"),
    "Nörkreatur": ("Nötkreatur", "Nötkreatur", "", "Bos", "Bovidae", "Artiodactyla"),
    "Nötkreatur": ("Nötkreatur", "Nötkreatur", "", "Bos", "Bovidae", "Artiodactyla"),
    "Nötkrestur": ("Nötkreatur", "Nötkreatur", "", "Bos", "Bovidae", "Artiodactyla"),
    "ötkreatur": ("Nötkreatur", "Nötkreatur", "", "Bos", "Bovidae", "Artiodactyla"),
    "Nötboskap": ("Nötboskap", "Nötkreatur", "", "Bos", "Bovidae", "Artiodactyla"),
    "Nötfiber": ("Nötfiber", "Nötkreatur", "", "Bos", "Bovidae", "Artiodactyla"),
    "Nöthår": ("Nöthår", "Nötkreatur", "", "Bos", "Bovidae", "Artiodactyla"),
    "Nöt": ("Nöt", "Nötkreatur", "", "Bos", "Bovidae", "Artiodactyla"),
    "kor": ("Nötkreatur", "Nötkreatur", "", "Bos", "Bovidae", "Artiodactyla"),

    # === Aurochs ===
    "Uroxe": ("Uroxe", "Uroxe", "", "primigenius", "Bos", "Bovidae", "Artiodactyla"),

    # === Ungulate ===
    "Hovdjur": ("Hovdjur", "Hovdjur", "", "", "", "Artiodactyla"),
    "hovdjur": ("Hovdjur", "Hovdjur", "", "", "", "Artiodactyla"),

    # === Mammal ===
    "Däggdjur": ("Däggdjur", "Däggdjur", "", "", "", "Mammalia"),
    "däggdjur": ("Däggdjur", "Däggdjur", "", "", "", "Mammalia"),
    "Däggfjur": ("Däggdjur", "Däggdjur", "", "", "", "Mammalia"),

    # === Bone ===
    "ben": ("Ben", "Ben", "", "", "", ""),
    "Benved": ("Benved (trä)", "Benved", "", "", "", ""),
    "Djurben": ("Djurben", "Djurben", "", "", "", ""),

    # === Turtle ===
    "Kärrsköldpadda": ("Kärrsköldpadda", "Kärrsköldpadda", "", "orbicularis", "Emys", "Emydidae", "Testudines"),

    # === Human ===
    "Männinska": ("Människa", "Människa", "", "sapiens", "Homo", "Hominidae", "Primates"),
    "Människa": ("Människa", "Människa", "", "sapiens", "Homo", "Hominidae", "Primates"),
    "Männska": ("Människa", "Människa", "", "sapiens", "Homo", "Hominidae", "Primates"),
    "Hjärnsubstans": ("Hjärnsubstans", "Hjärnsubstans", "", "", "", ""),

    # === PLANTS - Bramble ===
    "Hallon": ("Hallon", "Hallon", "", "Rubus", "Rosaceae", "Rosales"),

    # === Bearberry ===
    "Hjortron": ("Hjortron", "Hjortron", "", "vitis-idaea", "Vaccinium", "Ericaceae", "Ericales"),
    "Stenbär": ("Stenbär", "Stenbär", "", "vitis-idaea", "Vaccinium", "Ericaceae", "Ericales"),

    # === Crowberry ===
    "Kråkbär": ("Kråkbär", "Kråkbär", "", "nigrum", "Empetrum", "Empetraceae", "Ericales"),

    # === Heather ===
    "Ljung": ("Ljung", "Ljung", "", "vulgaris", "Calluna", "Ericaceae", "Ericales"),

    # === Vaccinium ===
    "Vaccinium": ("Vaccinium", "Vaccinium", "", "", "Vaccinium", "Ericaceae", "Ericales"),

    # === Nettle ===
    "Brännässla": ("Brännässla", "Brännässla", "", "dioica", "Urtica", "Urticaceae", "Rosales"),

    # === Ivy ===
    "Murgröna": ("Murgröna", "Murgröna", "", "helix", "Hedera", "Araliaceae", "Apiales"),

    # === Hop ===
    "Humle": ("Humle", "Humle", "", "lupulus", "Humulus", "Cannabaceae", "Rosales"),

    # === Hemp ===
    "Hampa": ("Hampa", "Hampa", "", "sativa", "Cannabis", "Cannabaceae", "Rosales"),

    # === Flax ===
    "Lin": ("Lin", "Lin", "", "usitatissimum", "Linum", "Linaceae", "Malpighiales"),
    "Linfiber": ("Linfiber", "Lin", "", "Linum", "Linaceae", "Malpighiales"),
    "Linfrö": ("Linfrö", "Lin", "", "Linum", "Linaceae", "Malpighiales"),

    # === Clover ===
    "Vicker": ("Vicker", "Vicker", "", "", "Trifolium", "Fabaceae", "Fabales"),

    # === Chickweed ===
    "Småsnärja": ("Småsnärja", "Småsnärja", "", "media", "Stellaria", "Caryophyllaceae", "Caryophyllales"),
    "Snärjmåra": ("Snärjmåra", "Snärjmåra", "", "", "Stellaria", "Caryophyllaceae", "Caryophyllales"),
    "Måra": ("Måra", "Måra", "", "", "Stellaria", "Caryophyllaceae", "Caryophyllales"),

    # === Iris ===
    "Iris": ("Iris", "Iris", "", "", "Iris", "Iridaceae", "Asparagales"),

    # === Garlic ===
    "Ramslök": ("Ramslök", "Ramslök", "", "ursinum", "Allium", "Amaryllidaceae", "Asparagales"),

    # === Rose ===
    "Ros": ("Ros", "Ros", "", "", "Rosa", "Rosaceae", "Rosales"),

    # === Brudbröd ===
    "Brudberöd": ("Brudbröd", "Brudbröd", "", "", "", ""),
    "Brudbröd": ("Brudbröd", "Brudbröd", "", "", "", ""),

    # === Bergssyra ===
    "Bergssyra": ("Bergssyra", "Bergssyra", "", "", "Sorbus", "Rosaceae", "Rosales"),

    # === Grass ===
    "Gräs": ("Gräs", "Gräs", "", "", "Poaceae", "Poales"),
    "Grässtrå": ("Grässtrå", "Gräs", "", "", "Poaceae", "Poales"),
    "Grässtrån": ("Grässtrå", "Gräs", "", "", "Poaceae", "Poales"),
    "Halm": ("Halm", "Halm", "", "", "Poaceae", "Poales"),
    "Halmstrå": ("Halmstrå", "Halm", "", "", "Poaceae", "Poales"),
    "Strå": ("Strå", "Strå", "", "", "Poaceae", "Poales"),
    "Kornhalm": ("Kornhalm", "Korn", "", "", "Poaceae", "Poales"),
    "Ogräs": ("Ogräs", "Ogräs", "", "", "Poaceae", "Poales"),

    # === Cereal grains ===
    "Vete": ("Vete", "Vete", "", "Triticum", "Poaceae", "Poales"),
    "Brödvete": ("Brödvete", "Vete", "", "Triticum", "Poaceae", "Poales"),
    "kubbvete": ("Kubbvete", "Kubbvete", "", "Triticum", "Poaceae", "Poales"),
    "Kubbvete": ("Kubbvete", "Kubbvete", "", "Triticum", "Poaceae", "Poales"),
    "Skalvete": ("Skalvete", "Vete", "", "Triticum", "Poaceae", "Poales"),
    "Triticum": ("Vete", "Vete", "", "Triticum", "Poaceae", "Poales"),
    "Korn": ("Korn", "Korn", "", "", "Poaceae", "Poales"),
    "korn": ("Korn", "Korn", "", "", "Poaceae", "Poales"),
    "Skalkorn": ("Skalkorn", "Korn", "", "", "Poaceae", "Poales"),
    "Säd": ("Säd", "Säd", "", "", "Poaceae", "Poales"),
    "Sädeskorn": ("Sädeskorn", "Korn", "", "", "Poaceae", "Poales"),
    "Cerealia": ("Cerealia (säd)", "Säd", "", "", "Poaceae", "Poales"),
    "Ceralia": ("Cerealia (säd)", "Säd", "", "", "Poaceae", "Poales"),
    "Cerelia": ("Cerealia (säd)", "Säd", "", "", "Poaceae", "Poales"),
    "Cereralia": ("Cerealia (säd)", "Säd", "", "", "Poaceae", "Poales"),
    "Crerealia": ("Cerealia (säd)", "Säd", "", "", "Poaceae", "Poales"),
    "Ceerealia indet": ("Cerealia indet", "Säd", "", "", "Poaceae", "Poales"),

    # === Subfamilies ===
    "Maloidea": ("Maloideae (underfamilj)", "Ärtväxt", "", "", "Fabaceae", "Fabales"),
    "Maloideae": ("Maloideae (underfamilj)", "Ärtväxt", "", "", "Fabaceae", "Fabales"),
    "Maloidear": ("Maloideae (underfamilj)", "Ärtväxt", "", "", "Fabaceae", "Fabales"),
    "Pomoidea": ("Pomoideae (underfamilj)", "Rosväxt", "", "", "Rosaceae", "Rosales"),
    "Pomoideae": ("Pomoideae (underfamilj)", "Rosväxt", "", "", "Rosaceae", "Rosales"),
    "Rosoideae": ("Rosoideae (underfamilj)", "Rosväxt", "", "", "Rosaceae", "Rosales"),
    "Rosväxt": ("Rosväxt", "Rosväxt", "", "", "Rosaceae", "Rosales"),
    "Korgblommiga": ("Korgblommiga", "Korgblommiga", "", "", "Asteraceae", "Asterales"),

    # === Spelt ===
    "Spel": ("Spelt", "Spelt", "", "spelta", "Triticum", "Poaceae", "Poales"),
    "Spelt": ("Spelt", "Spelt", "", "spelta", "Triticum", "Poaceae", "Poales"),
    "Spelt-": ("Spelt", "Spelt", "", "spelta", "Triticum", "Poaceae", "Poales"),
    "Speltvete": ("Speltvete", "Spelt", "", "spelta", "Triticum", "Poaceae", "Poales"),

    # === Emmer ===
    "Emme": ("Emmer", "Emmer", "", "dicoccum", "Triticum", "Poaceae", "Poales"),
    "Emmer": ("Emmer", "Emmer", "", "dicoccum", "Triticum", "Poaceae", "Poales"),
    "Emmervete": ("Emmervete", "Emmer", "", "dicoccum", "Triticum", "Poaceae", "Poales"),
    "emmervete": ("Emmervete", "Emmer", "", "dicoccum", "Triticum", "Poaceae", "Poales"),

    # === Einkorn ===
    "Enkorn": ("Enkorn", "Enkorn", "", "monococcum", "Triticum", "Poaceae", "Poales"),

    # === Dinkel/Spelt ===
    "Dinkel": ("Dinkel", "Spelt", "", "spelta", "Triticum", "Poaceae", "Poales"),

    # === Rye ===
    "Råg": ("Råg", "Råg", "", "cereale", "Secale", "Poaceae", "Poales"),
    "Råglosta": ("Råglosta", "Råg", "", "Secale", "Poaceae", "Poales"),

    # === Naked barley ===
    "Dån": ("Dån (kärnved)", "Kärnved", "", "vulgare", "Hordeum", "Poaceae", "Poales"),

    # === Oat ===
    "Haver": ("Haver", "Haver", "", "sativa", "Avena", "Poaceae", "Poales"),
    "Havre": ("Haver", "Haver", "", "sativa", "Avena", "Poaceae", "Poales"),
    "Knylhavre": ("Knylhavre", "Knylhavre", "", "fatua", "Avena", "Poaceae", "Poales"),
    "Pärlhavre": ("Pärlhavre", "Pärlhavre", "", "sativa", "Avena", "Poaceae", "Poales"),

    # === Millet ===
    "Hirs": ("Hirs", "Hirs", "", "", "Panicum", "Poaceae", "Poales"),

    # === Pea ===
    "Gråärt": ("Gråärt", "Gråärt", "", "", "Pisum", "Fabaceae", "Fabales"),
    "Ärta": ("Ärta", "Ärta", "", "", "Pisum", "Fabaceae", "Fabales"),

    # === Wild carrot ===
    "Svalört": ("Svalört", "Svalört", "", "carota", "Daucus", "Apiaceae", "Apiales"),
    "Svalörtsrot": ("Svalörtsrot", "Svalört", "", "carota", "Daucus", "Apiaceae", "Apiales"),

    # === Plantain ===
    "Vattenstäkra": ("Vattenstäkra", "Vattenstäkra", "", "lanceolata", "Plantago", "Plantaginaceae", "Lamiales"),

    # === Parsnip ===
    "Palsternacka": ("Palsternacka", "Palsternacka", "", "sativa", "Pastinaca", "Apiaceae", "Apiales"),

    # === Vetch ===
    "Svinmålla": ("Svinmålla", "Svinmålla", "", "sativa", "Vicia", "Fabaceae", "Fabales"),
    "Bitterpilört": ("Bitterpilört", "Bitterpilört", "", "", "Gentiana", "Gentianaceae", "Gentianales"),

    # === Åkerkrassling ===
    "Åkerkrassling": ("Åkerkrassling", "Åkerkrassling", "", "", "", ""),
    "Åkerpilört": ("Åkerpilört", "Åkerpilört", "", "", "Gentianaceae", "Gentianales"),
    "Trampört": ("Trampört", "Trampört", "", "", "", ""),

    # === Sedge ===
    "Starr": ("Starr", "Starr", "", "", "Carex", "Cyperaceae", "Poales"),
    "Cyperaceae": ("Starr (familj)", "Starr", "", "", "Cyperaceae", "Poales"),

    # === Buttercup ===
    "Smörblomma": ("Smörblomma", "Smörblomma", "", "", "Ranunculus", "Ranunculaceae", "Ranunculales"),
    "Tiggarranunkel": ("Tiggarranunkel", "Tiggarranunkel", "", "", "Ranunculus", "Ranunculaceae", "Ranunculales"),

    # === Apple ===
    "Äpple": ("Äpple", "Äpple", "", "", "Malus", "Rosaceae", "Rosales"),
    "Äppelkärna": ("Äppelkärna", "Äpple", "", "", "Malus", "Rosaceae", "Rosales"),

    # === Olive ===
    "Olvon": ("Olvon", "Olvon", "", "", "Olea", "Oleaceae", "Lamiales"),
    "Skogsolvon": ("Skogsolvon", "Skogsolvon", "", "", "Olea", "Oleaceae", "Lamiales"),

    # === Grape ===
    "Vindruvskärna": ("Vindruvskärna", "Vindruva", "", "", "Vitis", "Vitaceae", "Vituales"),

    # === Moss ===
    "Mossa": ("Mossa", "Mossa", "", "", "", "Bryophyta"),

    # === Resin ===
    "Harts": ("Harts", "Harts", "", "", "", ""),

    # === Bread ===
    "Bröd": ("Bröd", "Bröd", "", "", "", ""),
    "Gröt": ("Gröt", "Gröt", "", "", "", ""),

    # === Bark ===
    "Bark": ("Bark", "Bark", "", "", "", ""),
    "Näver": ("Näver", "Näver", "", "", "", ""),
    "Brunskära": ("Brunskära", "Brunskära", "", "", "", ""),

    # === Wood parts ===
    "Basstamdelar": ("Bastamdelar", "Bastamdelar", "", "", "", ""),
    "Brakved": ("Brakved", "Brakved", "", "", "", ""),
    "Stamdelar": ("Stamdelar", "Stamdelar", "", "", "", ""),
    "Kvist": ("Kvist", "Kvist", "", "", "", ""),
    "Oxel": ("Oxel", "Oxel", "", "", "", ""),
    "Träkol": ("Träkol", "Träkol", "", "", "", ""),

    # === Seed/pod parts ===
    "Baljfragment": ("Baljfragment", "Baljfragment", "", "", "", ""),
    "Frökapsel": ("Frökapsel", "Frökapsel", "", "", "", ""),
    "Fröskal": ("Fröskal", "Fröskal", "", "", "", ""),
    "Enfrön": ("Enfrön", "Enfrön", "", "", "", ""),

    # === Root ===
    "Rot": ("Rot", "Rot", "", "", "", ""),
    "Rotfilt": ("Rotfilt", "Rotfilt", "", "", "", ""),
    "Rottråd": ("Rottråd", "Rottråd", "", "", "", ""),
    "Rottrådar": ("Rottrådar", "Rottråd", "", "", "", ""),
    "Rotttrådar": ("Rottrådar", "Rottråd", "", "", "", ""),
    "rottrådar": ("Rottrådar", "Rottråd", "", "", "", ""),
    "Rhizom": ("Rhizom", "Rhizom", "", "", "", ""),
    "Tandrot": ("Tandrot", "Tandrot", "", "", "", ""),

    # === Bud ===
    "Knopp": ("Knopp", "Knopp", "", "", "", ""),
    "Igelknopp": ("Igelknopp", "Igelknopp", "", "", "", ""),

    # === Leaf ===
    "Lid": ("Lid (löv)", "Löv", "", "", "", ""),

    # === Hair ===
    "Hår": ("Hår", "Hår", "", "", "", ""),

    # === Horn ===
    "Horn": ("Horn", "Horn", "", "", "", ""),

    # === Leather ===
    "Läder": ("Läder", "Läder", "", "", "", ""),

    # === Wool ===
    "Ull": ("Ull", "Ull", "", "", "", ""),
    "Tagel": ("Tagel", "Tagel", "", "", "", ""),

    # === Textile ===
    "Textil": ("Textil", "Textil", "", "", "", ""),
    "Textilfragment": ("Textilfragment", "Textil", "", "", "", ""),
    "Ulltextil": ("Ulltextil", "Ulltextil", "", "", "", ""),
    "Tågvirke": ("Tågvirke", "Tågvirke", "", "", "", ""),
    "Tibast": ("Tibast", "Tibast", "", "", "", ""),

    # === Amber/Wax ===
    "Bivax": ("Bivax", "Bivax", "", "", "", ""),
    "Jurpa": ("Jurpa", "Jurpa", "", "", "", ""),

    # === Oyster ===
    "Ostron": ("Ostron", "Ostron", "", "", "", ""),

    # === Pollen ===
    "Pollen": ("Pollen", "Pollen", "", "", "", ""),

    # === Macrofossil ===
    "Makrofossil": ("Makrofossil", "Makrofossil", "", "", "", ""),

    # === Coprolite ===
    "Koprolit": ("Koprolit", "Koprolit", "", "", "", ""),

    # === Indeterminate ===
    "Indet": ("Indet (okänt)", "Indet", "", "", "", ""),
    "Oid": ("Oid (okänt)", "Okänt", "", "", "", ""),
    "Okänt": ("Okänt", "Okänt", "", "", "", ""),
    "Oförkolnat": ("Oförkolnat material", "Oförkolnat", "", "", "", ""),
    "Sot": ("Sot", "Sot", "", "", "", ""),
    "Sotig": ("Sotig", "Sotig", "", "", "", ""),
    "Try": ("Trä", "Trä", "", "", "", ""),

    # === Plant material general ===
    "ört": ("Ört", "Ört", "", "", "", ""),
    "Ört": ("Ört", "Ört", "", "", "", ""),
    "Örtdelar": ("Örtdelar", "Ört", "", "", "", ""),
    "Örtfragment": ("Örtfragment", "Ört", "", "", "", ""),
    "Örtstam": ("Örtstam", "Ört", "", "", "", ""),
    "Örtstam;;rot": ("Örtstam", "Ört", "", "", "", ""),
    "Örtstjälk": ("Örtstjälk", "Ört", "", "", "", ""),
    "Örtstjälkar": ("Örtstjälkar", "Ört", "", "", "", ""),
    "Växtdelar": ("Växtdelar", "Växtdelar", "", "", "", ""),

    # === Food remains ===
    "matrester": ("Matrester", "Matrester", "", "", "", ""),

    # === Vegetation ===
    "markvegetation": ("Markvegetation", "Markvegetation", "", "", "", ""),

    # === Stone fruits ===
    "Staeefrukter": ("Stenfrukter", "Stenfrukt", "", "", "Rosaceae", "Rosales"),
    "Starrfrukt": ("Starrfrukt", "Starrfrukt", "", "", "", ""),
    "Starrfrukter": ("Starrfrukter", "Starrfrukt", "", "", "", ""),

    # === Tick ===
    "Ticka": ("Ticka", "Ticka", "", "", "Ixodida", "Arachnida"),

    # === Forge maggots ===
    "Smidesloppor": ("Smidesloppor", "Smidesloppor", "", "", "", ""),

    # === Non-biological ===
    "Amulettring": ("Amulettring", "Amulettring", "", "", "", ""),
    "Kalkbruk": ("Kalkbruk", "Kalkbruk", "", "", "", ""),

    # === Cotton ===
    "Tuvull": ("Tuvull", "Tuvull", "", "", "Malvaceae", "Malvales"),

    # === Cone scale ===
    "Kotefjjäl": ("Kottefjäll", "Kottefjäll", "", "", "", ""),
    "Kottefjäll": ("Kottefjäll", "Kottefjäll", "", "", "", ""),

    # === Mushroom ===
    "Matskopa": ("Matskopa", "Matskopa", "", "", "", ""),
    "Matskorpa": ("Matskorpa", "Matskorpa", "", "", "", ""),

    # === Unknown ===
    "Mjölon": ("Mjölon", "Mjölon", "", "", "", ""),

    # === Ren misspelling ===
    "ran": ("Ren", "Ren", "", "tarandus", "Rangifer", "Cervidae", "Artiodactyla"),

    # === Torne ===
    "Torne": ("Torne", "Torne", "", "", "", ""),

    # === Horse bean ===
    "Hästböna": ("Hästböna", "Hästböna", "", "", "Fabaceae", "Fabales"),

    # === Bay laurel ===
    "Lager": ("Lager (baylöv)", "Lager", "", "", "Lauraceae", "Laurales"),

    # === Bär ===
    "Bärris": ("Bärris", "Bärris", "", "", "", ""),

    # === Gåsört (horsetail) ===
    "Gåsört": ("Gåsört", "Gåsört", "", "", "Equisetaceae", "Polypodiales"),

    # === Nate ===
    "Nate": ("Nate", "Nate", "", "", "", ""),

    # === Stål ===
    "Stål": ("Stål", "Stål", "", "", "", ""),

    # === Vikare ===
    "Vikare": ("Vikaresäl", "Vikaresäl", "", "sibirica", "Pusa", "Phocidae", "Carnivora"),

    # === Vildapel ===
    "Vildapel": ("Vildapelsin", "Vildapelsin", "", "", "Rutaceae", "Sapindales"),
}

# Process CSV
input_file = "/home/johan/sead-deployment/riia-list/list.csv"
output_file = "/home/johan/sead-deployment/riia-list/output.csv"

results = []

with open(input_file, 'r', encoding='utf-8-sig') as f:
    reader = csv.reader(f, delimiter=';')
    for row in reader:
        if not row:
            continue
        term = row[0].strip() if row[0] else ''
        if not term:
            continue

        # Look up inference
        inferred = INFERENCE.get(term, None)

        if inferred:
            inferred_meaning = inferred[0]
            common_name = inferred[1]
            species = inferred[2]
            genus = inferred[3]
            family = inferred[4]
            order = inferred[5]
        else:
            inferred_meaning = term
            common_name = ''
            species = ''
            genus = ''
            family = ''
            order = ''
            print(f"WARNING: No inference for term: '{term}'", file=sys.stderr)

        # Match common name (exact only)
        cn_match, cn_id = find_common_name_match(common_name)

        # Match species
        sp_match, sp_taxon_id, sp_chain = find_species_match(species, genus)

        # Match genus
        g_match, g_id, g_family_id = find_genus_match(genus)

        # Match family
        f_match, f_id, f_order_id = find_family_match(family)

        # Match order
        o_match, o_id = find_order_match(order)

        # If we got a species match, extract full chain
        if sp_chain:
            species = f"{sp_chain[3]} {sp_chain[1]}"
            genus = sp_chain[3]
            family = sp_chain[5]
            order = sp_chain[7]
            g_id = sp_chain[2]
            f_id = sp_chain[4]
            o_id = sp_chain[6]
            g_match = sp_chain[3]
            f_match = sp_chain[5]
            o_match = sp_chain[7]

        # Taxon_id from species or common name
        taxon_id = sp_taxon_id if sp_taxon_id else cn_id

        # If cn gave us a taxon_id but no species match, get chain from DB
        if cn_id and not sp_taxon_id:
            cur.execute("""
                SELECT ttm.species, ttg.genus_name, ttf.family_name, tto.order_name,
                       ttg.genus_id, ttf.family_id, tto.order_id
                FROM tbl_taxa_tree_master ttm
                JOIN tbl_taxa_tree_genera ttg ON ttm.genus_id = ttg.genus_id
                JOIN tbl_taxa_tree_families ttf ON ttg.family_id = ttf.family_id
                JOIN tbl_taxa_tree_orders tto ON ttf.order_id = tto.order_id
                WHERE ttm.taxon_id = %s
            """, (cn_id,))
            chain = cur.fetchone()
            if chain:
                if not species:
                    species = f"{chain[1]} {chain[0]}"
                if not genus:
                    genus = chain[1]
                if not family:
                    family = chain[2]
                if not order:
                    order = chain[3]
                if not g_id:
                    g_id = chain[4]
                if not f_id:
                    f_id = chain[5]
                if not o_id:
                    o_id = chain[6]
                if not sp_match:
                    sp_match = f"{chain[1]} {chain[0]}"
                if not g_match:
                    g_match = chain[1]
                if not f_match:
                    f_match = chain[2]
                if not o_match:
                    o_match = chain[3]

        # If genus matched, get family/order from genus chain
        if g_id and not f_id:
            cur.execute("SELECT family_id FROM tbl_taxa_tree_genera WHERE genus_id = %s", (g_id,))
            r = cur.fetchone()
            if r:
                f_id = r[0]
                cur.execute("SELECT family_name, order_id FROM tbl_taxa_tree_families WHERE family_id = %s", (f_id,))
                r2 = cur.fetchone()
                if r2:
                    if not f_match:
                        f_match = r2[0]
                    if not o_id:
                        o_id = r2[1]
                        cur.execute("SELECT order_name FROM tbl_taxa_tree_orders WHERE order_id = %s", (o_id,))
                        r3 = cur.fetchone()
                        if r3 and not o_match:
                            o_match = r3[0]

        # If family matched, get order
        if f_id and not o_id:
            cur.execute("SELECT order_id FROM tbl_taxa_tree_families WHERE family_id = %s", (f_id,))
            r = cur.fetchone()
            if r:
                o_id = r[0]
                cur.execute("SELECT order_name FROM tbl_taxa_tree_orders WHERE order_id = %s", (o_id,))
                r2 = cur.fetchone()
                if r2 and not o_match:
                    o_match = r2[0]

        # Clean up empty IDs
        if not taxon_id:
            taxon_id = ''
        if not g_id:
            g_id = ''
        if not f_id:
            f_id = ''
        if not o_id:
            o_id = ''

        results.append([
            term,
            inferred_meaning,
            common_name,
            species,
            genus,
            family,
            cn_match,
            cn_id,
            sp_match,
            g_match,
            f_match,
            o_match,
            taxon_id,
            g_id,
            f_id,
            o_id
        ])

# Write output
with open(output_file, 'w', encoding='utf-8', newline='') as f:
    writer = csv.writer(f, delimiter=';', quoting=csv.QUOTE_MINIMAL)
    writer.writerow([
        'Original term', 'Inferred meaning', 'Common name', 'Species', 'Genus', 'Family',
        'Common name match', 'Common name id', 'Species match', 'Genus match',
        'Family match', 'Order match', 'Taxon_id', 'Genus_id', 'Family_id', 'Order_id'
    ])
    for row in results:
        writer.writerow(row)

print(f"Written {len(results)} rows to {output_file}")
# Count matches
cn_matches = sum(1 for r in results if r[6])
sp_matches = sum(1 for r in results if r[8])
g_matches = sum(1 for r in results if r[9])
f_matches = sum(1 for r in results if r[10])
o_matches = sum(1 for r in results if r[11])
print(f"Common name matches: {cn_matches}/{len(results)}")
print(f"Species matches: {sp_matches}/{len(results)}")
print(f"Genus matches: {g_matches}/{len(results)}")
print(f"Family matches: {f_matches}/{len(results)}")
print(f"Order matches: {o_matches}/{len(results)}")

cur.close()
conn.close()
