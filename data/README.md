# Offline dictionary of Word Wise

`wordwise_offline.db` is the dictionary the offline mode of Word Wise reads
(Settings > AI Assistant > Word Wise > Hint Source). It is used when no
dictionary of your own is present (see below), and it works without internet
and without an AI provider.

It is the open dictionary of the wordwise.koplugin project
(https://github.com/asxelot/wordwise.koplugin), about 29,500 rare English
words, built only from open ingredients:

- word list: Open English WordNet lemmas
- difficulty: word frequency from the `wordfreq` package
- short definitions: written for that project

It contains no Kindle / Merriam-Webster content. Check the licences of the
sources above before redistributing it further.

## Schema

    entries(word TEXT PRIMARY KEY COLLATE NOCASE,
            short_def TEXT NOT NULL,     -- the hint
            difficulty INTEGER NOT NULL, -- 1 rarest .. 5 most common
            pos TEXT)                    -- optional

## A dictionary of your own

A database of the same shape saved as `<KOReader data dir>/wordwise/wordwise.db`
(or any `*.db` in that folder) is used instead of this one. On a Kindle with
its own Word Wise data, Settings > Word Wise > Offline Dictionary > "Use
Kindle's Word Wise Data" converts it once into such a file (personal use only,
never distribute it).
