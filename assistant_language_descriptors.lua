--[[
Language descriptor guidance
============================
This file stores language-specific knobs for the ranking pipeline. Each top-level key (e.g.
`en`, `es`) defines a descriptor table consumed by LanguageRankers. The structure is:

{
    enabled_features = { ... },   -- optional overrides; unspecified items fall back to the
                                  -- defaults declared in LanguageRankers._default_features
    word_groups = { ... },        -- optional list of word buckets used by the descriptor_words
                                  -- feature. Each entry takes the form { weight = <number>,
                                  -- words = { "token", ... } }.
    patterns = { ... },           -- optional regex patterns for descriptor_patterns feature.
    custom = function(context, metadata)
        -- optional bespoke scoring hook. Return a numeric bonus. If omitted, the custom
        -- feature should be disabled in `enabled_features`.
    end,
}

Tips for contributors
---------------------
* Keep word lists ASCII when possible so the repository stays portable. If you need diacritics,
  ensure the file encoding remains UTF-8.
* Use lower-case tokens; the ranker lowercases input before matching.
* Weights are additive. Doubling a weight doubles the contribution of matching tokens.
* To disable an entire feature for a language, set `enabled_features.feature_name = false`.
* When designing descriptors for a new language, start small (core colours/body words) and
  iteratively expand based on real book samples.

The module simply returns this table; no additional logic should live here.
]]
return {
    en = {
        enabled_features = {
            term_frequency = true,
            preferred_length = true,
            position_diversity = true,
            descriptor_words = true,
            descriptor_patterns = true,
            dialogue = true,
            proximity = true,
        },
        word_groups = {
            { weight = 3, words = {
                'red', 'blue', 'green', 'yellow', 'black', 'white', 'brown', 'gray', 'grey', 'golden', 'silver', 'dark', 'light', 'pale', 'bright',
                'tall', 'short', 'large', 'small', 'huge', 'tiny', 'wide', 'narrow', 'thick', 'thin', 'broad', 'slender', 'massive', 'enormous', 'crimson', 'scarlet', 'ivory', 'azure', 'violet', 'amber', 'bronze', 'charcoal', 'indigo', 'emerald', 'cobalt', 'ochre', 'pastel', 'glossy', 'neon', 'matte', 'translucent', 'luminous', 'holographic', 'chrome',
            }},
            { weight = 4, words = {
                'eyes', 'hair', 'face', 'hands', 'arms', 'legs', 'nose', 'mouth', 'lips', 'chin', 'forehead', 'cheeks', 'beard', 'mustache',
                'shoulders', 'chest', 'back', 'skin', 'complexion', 'build', 'figure', 'stature', 'posture', 'gait', 'voice', 'eyebrows', 'eyelashes', 'jaw', 'jawline', 'torso', 'waist', 'hips', 'ankles', 'wrists', 'fingers', 'toes', 'freckles', 'tattoo', 'scar', 'piercing', 'cybernetic', 'prosthetic', 'augmented',
            }},
            { weight = 3, words = {
                'building', 'house', 'castle', 'tower', 'room', 'hall', 'chamber', 'garden', 'courtyard', 'street', 'road', 'path', 'bridge',
                'mountain', 'hill', 'valley', 'river', 'lake', 'forest', 'field', 'meadow', 'desert', 'ocean', 'sea', 'shore', 'cliff',
                'walls', 'ceiling', 'floor', 'windows', 'doors', 'columns', 'stairs', 'roof', 'basement', 'attic', 'village', 'hamlet', 'harbor', 'port', 'market', 'plaza', 'alley', 'archway', 'balcony', 'terrace', 'veranda', 'hallway', 'corridor', 'doorway', 'arch', 'skyscraper', 'arcology', 'spaceport', 'starship', 'shuttle', 'airlock', 'hangar', 'laboratory', 'lab', 'factory', 'warehouse', 'apartment', 'loft', 'studio', 'cafeteria', 'diner', 'bar', 'club', 'observatory', 'colony', 'outpost', 'station',
            }},
            { weight = 3, words = {
                'dress', 'shirt', 'coat', 'cloak', 'robe', 'hat', 'cap', 'boots', 'shoes', 'gloves', 'ring', 'necklace', 'bracelet',
                'sword', 'dagger', 'staff', 'crown', 'helmet', 'armor', 'shield', 'belt', 'buckle', 'jewel', 'gem', 'tunic', 'vest', 'scarf', 'glasses', 'spectacles', 'brooch', 'gauntlet', 'satchel', 'sash', 'mantle', 'uniform', 'jumpsuit', 'hoodie', 'jeans', 'sneakers', 'trainers', 'loafers', 'heels', 'sandals', 'blazer', 'bodysuit', 'spacesuit', 'visor', 'utility belt', 'utility vest', 'lab coat', 'overalls', 'cardigan',
            }},
            { weight = 2, words = {
                'gleaming', 'glowing', 'sparkling', 'shimmering', 'glittering', 'blazing', 'flickering', 'shadowy', 'misty', 'clear',
                'cold', 'warm', 'hot', 'cool', 'freezing', 'burning', 'wet', 'dry', 'damp', 'moist', 'sticky', 'slippery',
                'loud', 'quiet', 'silent', 'echoing', 'ringing', 'whispering', 'thundering', 'creaking', 'rustling',
                'fragrant', 'sweet', 'bitter', 'sour', 'musty', 'fresh', 'stale', 'perfumed', 'smoky', 'hazy', 'murky', 'soothing', 'pungent', 'earthy', 'spicy', 'metallic', 'breezy', 'tingling', 'vivid', 'sterile', 'clinical', 'synthetic', 'ozonic', 'acrid', 'electric', 'humid', 'arid', 'resonant', 'radiant',
            }},
            { weight = 2, words = {
                'feet', 'inches', 'meters', 'miles', 'pounds', 'dozen', 'hundred', 'thousand', 'several', 'many', 'few', 'numerous', 'handful', 'pair', 'dozens', 'scores', 'multitude', 'plenty', 'countless', 'kilometers', 'liters', 'grams', 'gigabyte', 'terabyte', 'nanosecond', 'lightyear', 'parsec', 'megaton', 'percentage', 'ratio',
            }},
        },
        patterns = {
            { weight = 2, pattern = '%f[%a]like%f[%A]' },
            { weight = 2, pattern = 'as%s+%w+%s+as' },
            { weight = 2, pattern = '%f[%a]than%f[%A]' },
            { weight = 2, pattern = 'similar to' },
            { weight = 2, pattern = 'resembled' },
            { weight = 2, pattern = 'reminded%s+of' },
            { weight = 2, pattern = 'looked like' },
            { weight = 2, pattern = 'appeared to be' },
            { weight = 2, pattern = '%f[%a][A-Z][a-z]+%s+[A-Z][a-z]+%f[%A]', target = 'raw' },
            { weight = 2, pattern = '%f[%a]said%f[%A]' },
            { weight = 2, pattern = '%f[%a]asked%f[%A]' },
            { weight = 2, pattern = '%f[%a]replied%f[%A]' },
            { weight = 2, pattern = '%f[%a]thought%f[%A]' },
            { weight = 1, pattern = '%f[%a]because%f[%A]' },
            { weight = 1, pattern = '%f[%a]however%f[%A]' },
            { weight = 1, pattern = '%f[%a]therefore%f[%A]' },
            { weight = 1, pattern = '%f[%a]although%f[%A]' },
            { weight = 1, pattern = '%f[%a]suddenly%f[%A]' },
            { weight = 1, pattern = '%f[%a]finally%f[%A]' },
            { weight = 1, pattern = '%f[%a]meanwhile%f[%A]' },
        },
    },
    es = {
        enabled_features = {
            term_frequency = true,
            preferred_length = true,
            position_diversity = true,
            descriptor_words = true,
            descriptor_patterns = true,
            dialogue = true,
            proximity = true,
        },
        word_groups = {
            { weight = 3, words = {
                'rojo', 'azul', 'verde', 'amarillo', 'negro', 'blanco', 'marron', 'gris', 'dorado', 'plateado', 'oscuro', 'claro', 'palido', 'brillante',
                'alto', 'alta', 'bajo', 'baja', 'grande', 'pequeno', 'pequena', 'enorme', 'diminuto', 'ancho', 'estrecho',
            }},
            { weight = 4, words = {
                'ojos', 'pelo', 'cabello', 'cara', 'manos', 'brazos', 'piernas', 'nariz', 'boca', 'labios', 'barba', 'bigote',
                'hombros', 'pecho', 'espalda', 'piel', 'figura', 'cuerpo', 'estatura', 'voz',
            }},
            { weight = 3, words = {
                'edificio', 'casa', 'castillo', 'torre', 'habitacion', 'sala', 'jardin', 'patio', 'calle', 'camino', 'puente',
                'montana', 'colina', 'valle', 'rio', 'lago', 'bosque', 'campo', 'desierto', 'mar',
            }},
            { weight = 3, words = {
                'vestido', 'camisa', 'abrigo', 'capa', 'tunica', 'sombrero', 'botas', 'zapatos', 'guantes', 'anillo', 'collar', 'pulsera',
                'espada', 'daga', 'cetro', 'corona', 'armadura', 'escudo', 'cinturon',
            }},
            { weight = 2, words = {
                'reluciente', 'resplandeciente', 'brillo', 'sombrio', 'claro', 'calido', 'frio', 'caliente', 'helado', 'ardiente',
                'humedo', 'seco', 'suave', 'aspero', 'silencioso', 'ruidoso', 'fragante', 'dulce', 'amargo', 'fresco',
            }},
            { weight = 2, words = {
                'metros', 'kilometros', 'pies', 'pulgadas', 'kilos', 'docena', 'centena', 'miles', 'varios', 'muchos', 'pocos', 'numerosos',
            }},
        },
        patterns = {
            { weight = 2, pattern = '%f[%a]como%f[%A]' },
            { weight = 2, pattern = 'tan%s+%w+%s+como' },
            { weight = 2, pattern = 'parecido a' },
            { weight = 2, pattern = 'se parecia a' },
            { weight = 2, pattern = 'tenia aspecto de' },
            { weight = 2, pattern = '%f[%a][A-Z][a-z]+%s+[A-Z][a-z]+%f[%A]', target = 'raw' },
            { weight = 2, pattern = '%f[%a]dijo%f[%A]' },
            { weight = 2, pattern = '%f[%a]pregunto%f[%A]' },
            { weight = 2, pattern = '%f[%a]respondio%f[%A]' },
            { weight = 2, pattern = '%f[%a]penso%f[%A]' },
            { weight = 1, pattern = '%f[%a]porque%f[%A]' },
            { weight = 1, pattern = 'sin embargo' },
            { weight = 1, pattern = 'por tanto' },
            { weight = 1, pattern = '%f[%a]aunque%f[%A]' },
            { weight = 1, pattern = 'de repente' },
            { weight = 1, pattern = 'finalmente' },
            { weight = 1, pattern = 'mientras tanto' },
        },
    },
    fr = {
        enabled_features = {
            term_frequency = true,
            preferred_length = true,
            position_diversity = true,
            descriptor_words = true,
            descriptor_patterns = true,
            dialogue = true,
            proximity = true,
        },
        word_groups = {
            { weight = 3, words = {
                'rouge', 'bleu', 'vert', 'jaune', 'noir', 'blanc', 'brun', 'gris', 'dore', 'argent', 'sombre', 'clair', 'pale', 'brillant',
                'grand', 'grande', 'petit', 'petite', 'large', 'etroite', 'immense', 'mince',
            }},
            { weight = 4, words = {
                'yeux', 'cheveux', 'visage', 'mains', 'bras', 'jambes', 'nez', 'bouche', 'levres', 'barbe', 'moustache',
                'epaules', 'poitrine', 'dos', 'peau', 'silhouette', 'corps', 'taille', 'voix',
            }},
            { weight = 3, words = {
                'batiment', 'maison', 'chateau', 'tour', 'salle', 'chambre', 'jardin', 'cour', 'rue', 'route', 'pont',
                'montagne', 'colline', 'vallee', 'riviere', 'lac', 'foret', 'champ', 'desert', 'mer',
            }},
            { weight = 3, words = {
                'robe', 'chemise', 'manteau', 'cape', 'chapeau', 'bottes', 'souliers', 'gants', 'bague', 'collier', 'bracelet',
                'epee', 'dague', 'sceptre', 'couronne', 'armure', 'bouclier', 'ceinture',
            }},
            { weight = 2, words = {
                'brillant', 'etincelant', 'lumineux', 'ombre', 'clair', 'chaud', 'froid', 'glacial', 'brulant',
                'humide', 'sec', 'doux', 'rugueux', 'silencieux', 'bruyant', 'parfume', 'sucre', 'amer', 'frais',
            }},
            { weight = 2, words = {
                'metres', 'kilometres', 'pieds', 'pouces', 'kilos', 'douzaine', 'centaine', 'mille', 'plusieurs', 'nombreux', 'quelques', 'divers',
            }},
        },
        patterns = {
            { weight = 2, pattern = '%f[%a]comme%f[%A]' },
            { weight = 2, pattern = 'plus%s+%w+%s+que' },
            { weight = 2, pattern = 'semblable a' },
            { weight = 2, pattern = 'ressemblait' },
            { weight = 2, pattern = 'avait l'air' },
            { weight = 2, pattern = '%f[%a][A-Z][a-z]+%s+[A-Z][a-z]+%f[%A]', target = 'raw' },
            { weight = 2, pattern = '%f[%a]dit%f[%A]' },
            { weight = 2, pattern = '%f[%a]demanda%f[%A]' },
            { weight = 2, pattern = '%f[%a]repondit%f[%A]' },
            { weight = 2, pattern = '%f[%a]pensa%f[%A]' },
            { weight = 1, pattern = 'parce que' },
            { weight = 1, pattern = 'cependant' },
            { weight = 1, pattern = '%f[%a]donc%f[%A]' },
            { weight = 1, pattern = 'bien que' },
            { weight = 1, pattern = 'soudain' },
            { weight = 1, pattern = 'finalement' },
            { weight = 1, pattern = 'pendant ce temps' },
        },
    },
    de = {
        enabled_features = {
            term_frequency = true,
            preferred_length = true,
            position_diversity = true,
            descriptor_words = true,
            descriptor_patterns = true,
            dialogue = true,
            proximity = true,
        },
        word_groups = {
            { weight = 3, words = {
                'rot', 'blau', 'grun', 'gruen', 'gelb', 'schwarz', 'weiss', 'braun', 'grau', 'golden', 'silbern', 'dunkel', 'hell', 'blass', 'leuchtend',
                'gross', 'klein', 'breit', 'schmal', 'riesig', 'winzig',
            }},
            { weight = 4, words = {
                'augen', 'haare', 'gesicht', 'hand', 'haende', 'arm', 'arme', 'bein', 'beine', 'nase', 'mund', 'lippen', 'bart', 'schnurrbart',
                'schultern', 'brust', 'rucken', 'haut', 'gestalt', 'korper', 'statur', 'stimme',
            }},
            { weight = 3, words = {
                'gebaude', 'haus', 'schloss', 'turm', 'raum', 'halle', 'kammer', 'garten', 'hof', 'strasse', 'weg', 'brucke',
                'berg', 'hugel', 'tal', 'fluss', 'see', 'wald', 'feld', 'wuste', 'meer',
            }},
            { weight = 3, words = {
                'kleid', 'hemd', 'mantel', 'umhang', 'robe', 'hut', 'stiefel', 'schuhe', 'handschuhe', 'ring', 'kette', 'armband',
                'schwert', 'dolch', 'stab', 'krone', 'helm', 'rustung', 'schild', 'gurtel',
            }},
            { weight = 2, words = {
                'glanzend', 'leuchtend', 'funkelnd', 'schimmernd', 'strahlend', 'warm', 'heiss', 'kalt', 'frostig', 'brennend',
                'nass', 'trocken', 'weich', 'rau', 'leise', 'laut', 'duftend', 'suss', 'bitter', 'frisch',
            }},
            { weight = 2, words = {
                'meter', 'kilometer', 'fuss', 'zoll', 'pfund', 'dutzend', 'hundert', 'tausend', 'mehrere', 'viele', 'wenige', 'zahlreiche',
            }},
        },
        patterns = {
            { weight = 2, pattern = '%f[%a]wie%f[%A]' },
            { weight = 2, pattern = '%f[%a]als%f[%A]' },
            { weight = 2, pattern = 'ahnlich' },
            { weight = 2, pattern = 'erinnerte an' },
            { weight = 2, pattern = 'sah aus wie' },
            { weight = 2, pattern = '%f[%a][A-Z][a-z]+%s+[A-Z][a-z]+%f[%A]', target = 'raw' },
            { weight = 2, pattern = '%f[%a]sagte%f[%A]' },
            { weight = 2, pattern = '%f[%a]fragte%f[%A]' },
            { weight = 2, pattern = '%f[%a]antwortete%f[%A]' },
            { weight = 2, pattern = '%f[%a]dachte%f[%A]' },
            { weight = 1, pattern = '%f[%a]weil%f[%A]' },
            { weight = 1, pattern = '%f[%a]jedoch%f[%A]' },
            { weight = 1, pattern = '%f[%a]deshalb%f[%A]' },
            { weight = 1, pattern = '%f[%a]obwohl%f[%A]' },
            { weight = 1, pattern = 'plotzlich' },
            { weight = 1, pattern = 'schliesslich' },
            { weight = 1, pattern = 'inzwischen' },
        },
    },
}
