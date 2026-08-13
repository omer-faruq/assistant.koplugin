-- Unicode symbol/icon viewer test
-- Usage: ./test/runui.sh unicode_icons
--
-- Shows common Unicode symbols inside a plain dialog so you can check
-- which ones render with the fonts bundled in KOReader.
-- Layout per line: <symbol>  <codepoint>  <name>

-- Add project root to path before requiring wbuilder
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. package.path
end

local wb = require("test/wbuilder")
local UIManager = wb.UIManager
local Screen = wb.Screen

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

-- ── Symbol data ──

local sections = {
    { title = "Arrows & navigation", items = {
        {"←", "U+2190", "leftwards arrow"},
        {"↑", "U+2191", "upwards arrow"},
        {"→", "U+2192", "rightwards arrow"},
        {"↓", "U+2193", "downwards arrow"},
        {"↔", "U+2194", "left right arrow"},
        {"↕", "U+2195", "up down arrow"},
        {"↖", "U+2196", "north west arrow"},
        {"↗", "U+2197", "north east arrow"},
        {"↘", "U+2198", "south east arrow"},
        {"↙", "U+2199", "south west arrow"},
        {"↺", "U+21BA", "anticlockwise open circle arrow"},
        {"↻", "U+21BB", "clockwise open circle arrow"},
        {"⇄", "U+21C4", "rightwards arrow over leftwards arrow"},
        {"⇅", "U+21C5", "upwards arrow leftwards of downwards arrow"},
        {"⇦", "U+21E6", "leftwards white arrow"},
        {"⇧", "U+21E7", "upwards white arrow"},
        {"⇨", "U+21E8", "rightwards white arrow"},
        {"⇩", "U+21E9", "downwards white arrow"},
        {"⇐", "U+21D0", "leftwards double arrow"},
        {"⇒", "U+21D2", "rightwards double arrow"},
        {"⇔", "U+21D4", "left right double arrow"},
        {"↤", "U+21A4", "leftwards arrow from bar"},
        {"↦", "U+21A6", "rightwards arrow from bar"},
        {"⟵", "U+27F5", "long leftwards arrow"},
        {"⟶", "U+27F6", "long rightwards arrow"},
        {"⤴", "U+2934", "arrow pointing rightwards then curving upwards"},
        {"⤵", "U+2935", "arrow pointing rightwards then curving downwards"},
    }},
    { title = "UI / control symbols", items = {
        {"⌂", "U+2302", "house"},
        {"⌘", "U+2318", "place of interest sign"},
        {"⌥", "U+2325", "option key"},
        {"⎋", "U+238B", "broken circle with northwest arrow"},
        {"⏎", "U+23CE", "return symbol"},
        {"⌫", "U+232B", "erase to the left"},
        {"⌦", "U+2326", "erase to the right"},
        {"⏏", "U+23CF", "eject symbol"},
        {"☰", "U+2630", "trigram for heaven (hamburger)"},
        {"⚙", "U+2699", "gear"},
        {"⚡", "U+26A1", "high voltage"},
        {"⚠", "U+26A0", "warning sign"},
        {"⛔", "U+26D4", "no entry"},
        {"⚑", "U+2691", "black flag"},
        {"⚐", "U+2690", "white flag"},
        {"♺", "U+267A", "recycling symbol"},
        {"♻", "U+267B", "black universal recycling symbol"},
        {"⌕", "U+2315", "telephone recorder"},
        {"⏰", "U+23F0", "alarm clock"},
        {"⌛", "U+231B", "hourglass"},
        {"⌚", "U+231A", "watch"},
    }},
    { title = "Checks & crosses", items = {
        {"✓", "U+2713", "check mark"},
        {"✔", "U+2714", "heavy check mark"},
        {"✗", "U+2717", "ballot X"},
        {"✘", "U+2718", "heavy ballot X"},
        {"✕", "U+2715", "multiplication X"},
        {"✖", "U+2716", "heavy multiplication X"},
        {"☑", "U+2611", "ballot box with check"},
        {"☒", "U+2612", "ballot box with X"},
        {"☐", "U+2610", "ballot box"},
        {"☓", "U+2613", "saltire"},
        {"✅", "U+2705", "white heavy check mark"},
        {"❌", "U+274C", "cross mark"},
        {"⭕", "U+2B55", "heavy large circle"},
        {"⍻", "U+237B", "not check mark"},
    }},
    { title = "Stars & asterisks", items = {
        {"★", "U+2605", "black star"},
        {"☆", "U+2606", "white star"},
        {"✦", "U+2726", "black four pointed star"},
        {"✧", "U+2727", "white four pointed star"},
        {"✩", "U+2729", "stress outlined white star"},
        {"✪", "U+272A", "circled white star"},
        {"✫", "U+272B", "open centre black star"},
        {"✬", "U+272C", "black centre white star"},
        {"✭", "U+272D", "outlined black star"},
        {"✮", "U+272E", "heavy outlined black star"},
        {"✯", "U+272F", "pinwheel star"},
        {"✰", "U+2730", "shadowed white star"},
        {"✱", "U+2731", "heavy asterisk"},
        {"✲", "U+2732", "open centre asterisk"},
        {"✳", "U+2733", "eight spoked asterisk"},
        {"✴", "U+2734", "eight pointed black star"},
        {"✵", "U+2735", "eight pointed pinwheel star"},
        {"✶", "U+2736", "six pointed black star"},
        {"✷", "U+2737", "eight pointed rectilinear black star"},
        {"✸", "U+2738", "heavy eight pointed rectilinear black star"},
        {"✹", "U+2739", "twelve pointed black star"},
        {"❖", "U+2756", "black diamond minus white X"},
        {"⁂", "U+2042", "asterism"},
    }},
    { title = "Hearts, suits & music", items = {
        {"♥", "U+2665", "black heart suit"},
        {"♡", "U+2661", "white heart suit"},
        {"❤", "U+2764", "heavy black heart"},
        {"❥", "U+2765", "rotated heavy black heart bullet"},
        {"♠", "U+2660", "black spade suit"},
        {"♣", "U+2663", "black club suit"},
        {"♦", "U+2666", "black diamond suit"},
        {"♩", "U+2669", "quarter note"},
        {"♪", "U+266A", "eighth note"},
        {"♫", "U+266B", "beamed eighth notes"},
        {"♬", "U+266C", "beamed sixteenth notes"},
        {"♭", "U+266D", "music flat sign"},
        {"♮", "U+266E", "music natural sign"},
        {"♯", "U+266F", "music sharp sign"},
    }},
    { title = "Bullets & typography", items = {
        {"•", "U+2022", "bullet"},
        {"◦", "U+25E6", "white bullet"},
        {"▪", "U+25AA", "black small square"},
        {"▫", "U+25AB", "white small square"},
        {"‣", "U+2023", "triangular bullet"},
        {"․", "U+2024", "one dot leader"},
        {"…", "U+2026", "horizontal ellipsis"},
        {"–", "U+2013", "en dash"},
        {"—", "U+2014", "em dash"},
        {"―", "U+2015", "horizontal bar"},
        {"\226\128\152", "U+2018", "left single quotation mark"}, -- '
        {"\226\128\153", "U+2019", "right single quotation mark"}, -- '
        {"\226\128\156", "U+201C", "left double quotation mark"}, -- "
        {"\226\128\157", "U+201D", "right double quotation mark"}, -- "
        {"„", "U+201E", "double low-9 quotation mark"},
        {"‹", "U+2039", "single left-pointing angle quotation mark"},
        {"›", "U+203A", "single right-pointing angle quotation mark"},
        {"«", "U+00AB", "left-pointing double angle quotation mark"},
        {"»", "U+00BB", "right-pointing double angle quotation mark"},
        {"‽", "U+203D", "interrobang"},
        {"‼", "U+203C", "double exclamation mark"},
        {"⁈", "U+2048", "question exclamation mark"},
        {"⁉", "U+2049", "exclamation question mark"},
        {"※", "U+203B", "reference mark"},
        {"§", "U+00A7", "section sign"},
        {"¶", "U+00B6", "pilcrow sign"},
        {"†", "U+2020", "dagger"},
        {"‡", "U+2021", "double dagger"},
        {"°", "U+00B0", "degree sign"},
        {"′", "U+2032", "prime"},
        {"″", "U+2033", "double prime"},
        {"™", "U+2122", "trade mark sign"},
        {"©", "U+00A9", "copyright sign"},
        {"®", "U+00AE", "registered sign"},
        {"№", "U+2116", "numero sign"},
    }},
    { title = "Weather & nature", items = {
        {"☀", "U+2600", "black sun with rays"},
        {"☁", "U+2601", "cloud"},
        {"☂", "U+2602", "umbrella"},
        {"☃", "U+2603", "snowman"},
        {"☄", "U+2604", "comet"},
        {"☔", "U+2614", "umbrella with rain drops"},
        {"☕", "U+2615", "hot beverage"},
        {"❄", "U+2744", "snowflake"},
        {"☾", "U+263E", "last quarter moon"},
        {"☽", "U+263D", "first quarter moon"},
        {"♨", "U+2668", "hot springs"},
        {"⛅", "U+26C5", "sun behind cloud"},
        {"⚓", "U+2693", "anchor"},
    }},
    { title = "Mail & office", items = {
        {"✉", "U+2709", "envelope"},
        {"✎", "U+270E", "lower right pencil"},
        {"✏", "U+270F", "pencil"},
        {"✂", "U+2702", "black scissors"},
        {"✆", "U+2706", "telephone location sign"},
        {"☎", "U+260E", "black telephone"},
        {"☏", "U+260F", "white telephone"},
        {"✈", "U+2708", "airplane"},
        {"⌨", "U+2328", "keyboard"},
        {"✍", "U+270D", "writing hand"},
        {"⚖", "U+2696", "scales"},
        {"⚗", "U+2697", "alembic"},
        {"⚘", "U+2698", "flower"},
        {"⏱", "U+23F1", "stopwatch"},
    }},
    { title = "Currency", items = {
        {"$", "U+0024", "dollar sign"},
        {"¢", "U+00A2", "cent sign"},
        {"£", "U+00A3", "pound sign"},
        {"¥", "U+00A5", "yen sign"},
        {"€", "U+20AC", "euro sign"},
        {"¤", "U+00A4", "currency sign"},
        {"₽", "U+20BD", "ruble sign"},
        {"₹", "U+20B9", "indian rupee sign"},
        {"₺", "U+20BA", "turkish lira sign"},
        {"₿", "U+20BF", "bitcoin sign"},
        {"₩", "U+20A9", "won sign"},
        {"₫", "U+20AB", "dong sign"},
        {"₴", "U+20B4", "hryvnia sign"},
        {"₱", "U+20B1", "peso sign"},
        {"₪", "U+20AA", "new sheqel sign"},
    }},
    { title = "Geometric shapes", items = {
        {"■", "U+25A0", "black square"},
        {"□", "U+25A1", "white square"},
        {"▲", "U+25B2", "black up-pointing triangle"},
        {"△", "U+25B3", "white up-pointing triangle"},
        {"►", "U+25BA", "black right-pointing pointer"},
        {"▷", "U+25B7", "white right-pointing triangle"},
        {"▼", "U+25BC", "black down-pointing triangle"},
        {"▽", "U+25BD", "white down-pointing triangle"},
        {"◀", "U+25C0", "black left-pointing triangle"},
        {"◁", "U+25C1", "white left-pointing triangle"},
        {"◆", "U+25C6", "black diamond"},
        {"◇", "U+25C7", "white diamond"},
        {"●", "U+25CF", "black circle"},
        {"○", "U+25CB", "white circle"},
        {"◎", "U+25CE", "bullseye"},
        {"◉", "U+25C9", "fisheye"},
        {"◯", "U+25EF", "large circle"},
        {"◊", "U+25CA", "lozenge"},
        {"◈", "U+25C8", "white diamond containing black small diamond"},
        {"▣", "U+25A3", "white square containing black small square"},
        {"▤", "U+25A4", "square with horizontal fill"},
        {"▥", "U+25A5", "square with vertical fill"},
        {"▸", "U+25B8", "black right-pointing small triangle"},
        {"▹", "U+25B9", "white right-pointing small triangle"},
        {"◂", "U+25C2", "black left-pointing small triangle"},
        {"▬", "U+25AC", "black rectangle"},
        {"◘", "U+25D8", "inverse bullet"},
    }},
    { title = "Circled numbers & letters", items = {
        {"①", "U+2460", "circled digit one"},
        {"②", "U+2461", "circled digit two"},
        {"③", "U+2462", "circled digit three"},
        {"④", "U+2463", "circled digit four"},
        {"⑤", "U+2464", "circled digit five"},
        {"⑥", "U+2465", "circled digit six"},
        {"⑦", "U+2466", "circled digit seven"},
        {"⑧", "U+2467", "circled digit eight"},
        {"⑨", "U+2468", "circled digit nine"},
        {"⑩", "U+2469", "circled number ten"},
        {"⑪", "U+246A", "circled number eleven"},
        {"⑫", "U+246B", "circled number twelve"},
        {"⓪", "U+24EA", "circled digit zero"},
        {"❶", "U+2776", "dingbat negative circled digit one"},
        {"❷", "U+2777", "dingbat negative circled digit two"},
        {"❸", "U+2778", "dingbat negative circled digit three"},
        {"❹", "U+2779", "dingbat negative circled digit four"},
        {"❺", "U+277A", "dingbat negative circled digit five"},
        {"⑴", "U+2474", "parenthesized digit one"},
        {"⑵", "U+2475", "parenthesized digit two"},
        {"⑶", "U+2476", "parenthesized digit three"},
    }},
    { title = "Trigrams & misc dingbats", items = {
        {"☰", "U+2630", "trigram for heaven"},
        {"☱", "U+2631", "trigram for lake"},
        {"☲", "U+2632", "trigram for fire"},
        {"☳", "U+2633", "trigram for thunder"},
        {"☴", "U+2634", "trigram for wind"},
        {"☵", "U+2635", "trigram for water"},
        {"☶", "U+2636", "trigram for mountain"},
        {"☷", "U+2637", "trigram for earth"},
        {"☭", "U+262D", "hammer and sickle"},
        {"☮", "U+262E", "peace symbol"},
        {"☯", "U+262F", "yin yang"},
        {"☸", "U+2638", "wheel of dharma"},
        {"☪", "U+262A", "star and crescent"},
        {"☠", "U+2620", "skull and crossbones"},
        {"☢", "U+2622", "radioactive sign"},
        {"☣", "U+2623", "biohazard sign"},
        {"☤", "U+2624", "caduceus"},
        {"☺", "U+263A", "white smiling face"},
        {"☹", "U+2639", "white frowning face"},
        {"☻", "U+263B", "black smiling face"},
        {"♁", "U+2641", "earth"},
        {"♿", "U+267F", "wheelchair symbol"},
        {"⚔", "U+2694", "crossed swords"},
        {"⚕", "U+2695", "staff of aesculapius"},
        {"⚜", "U+269C", "fleur-de-lis"},
        {"⚛", "U+269B", "atom symbol"},
    }},
    { title = "Box drawing", items = {
        {"─", "U+2500", "box drawings light horizontal"},
        {"│", "U+2502", "box drawings light vertical"},
        {"┌", "U+250C", "box drawings light down and right"},
        {"┐", "U+2510", "box drawings light down and left"},
        {"└", "U+2514", "box drawings light up and right"},
        {"┘", "U+2518", "box drawings light up and left"},
        {"├", "U+251C", "box drawings light vertical and right"},
        {"┤", "U+2524", "box drawings light vertical and left"},
        {"┬", "U+252C", "box drawings light down and horizontal"},
        {"┴", "U+2534", "box drawings light up and horizontal"},
        {"┼", "U+253C", "box drawings light vertical and horizontal"},
        {"═", "U+2550", "box drawings double horizontal"},
        {"║", "U+2551", "box drawings double vertical"},
        {"╔", "U+2554", "box drawings double down and right"},
        {"╗", "U+2557", "box drawings double down and left"},
        {"╚", "U+255A", "box drawings double up and right"},
        {"╝", "U+255D", "box drawings double up and left"},
        {"╠", "U+2560", "box drawings double vertical and right"},
        {"╣", "U+2563", "box drawings double vertical and left"},
        {"╦", "U+2566", "box drawings double down and horizontal"},
        {"╩", "U+2569", "box drawings double up and horizontal"},
        {"╬", "U+256C", "box drawings double vertical and horizontal"},
        {"▁", "U+2581", "lower one eighth block"},
        {"▂", "U+2582", "lower one quarter block"},
        {"▃", "U+2583", "lower three eighths block"},
        {"▄", "U+2584", "lower half block"},
        {"▅", "U+2585", "lower five eighths block"},
        {"▆", "U+2586", "lower three quarters block"},
        {"▇", "U+2587", "lower seven eighths block"},
        {"█", "U+2588", "full block"},
        {"▌", "U+258C", "left half block"},
        {"▐", "U+2590", "right half block"},
        {"░", "U+2591", "light shade"},
        {"▒", "U+2592", "medium shade"},
        {"▓", "U+2593", "dark shade"},
    }},
    { title = "Math & fractions", items = {
        {"±", "U+00B1", "plus-minus sign"},
        {"×", "U+00D7", "multiplication sign"},
        {"÷", "U+00F7", "division sign"},
        {"≈", "U+2248", "almost equal to"},
        {"≠", "U+2260", "not equal to"},
        {"≤", "U+2264", "less-than or equal to"},
        {"≥", "U+2265", "greater-than or equal to"},
        {"∞", "U+221E", "infinity"},
        {"√", "U+221A", "square root"},
        {"∛", "U+221B", "cube root"},
        {"∜", "U+221C", "fourth root"},
        {"∑", "U+2211", "n-ary summation"},
        {"∏", "U+220F", "n-ary product"},
        {"∫", "U+222B", "integral"},
        {"∂", "U+2202", "partial differential"},
        {"∆", "U+2206", "increment"},
        {"∇", "U+2207", "nabla"},
        {"∈", "U+2208", "element of"},
        {"∉", "U+2209", "not an element of"},
        {"∅", "U+2205", "empty set"},
        {"∩", "U+2229", "intersection"},
        {"∪", "U+222A", "union"},
        {"⊂", "U+2282", "subset of"},
        {"⊃", "U+2283", "superset of"},
        {"⊆", "U+2286", "subset of or equal to"},
        {"⊇", "U+2287", "superset of or equal to"},
        {"⊕", "U+2295", "circled plus"},
        {"⊗", "U+2297", "circled times"},
        {"π", "U+03C0", "greek small letter pi"},
        {"λ", "U+03BB", "greek small letter lamda"},
        {"θ", "U+03B8", "greek small letter theta"},
        {"μ", "U+03BC", "greek small letter mu"},
        {"½", "U+00BD", "vulgar fraction one half"},
        {"⅓", "U+2153", "vulgar fraction one third"},
        {"⅔", "U+2154", "vulgar fraction two thirds"},
        {"¼", "U+00BC", "vulgar fraction one quarter"},
        {"¾", "U+00BE", "vulgar fraction three quarters"},
        {"‰", "U+2030", "per mille sign"},
    }},
    { title = "Emoji (likely tofu, for reference)", items = {
        {"😀", "U+1F600", "grinning face"},
        {"😂", "U+1F602", "face with tears of joy"},
        {"👍", "U+1F44D", "thumbs up"},
        {"👎", "U+1F44E", "thumbs down"},
        {"🎉", "U+1F389", "party popper"},
        {"📚", "U+1F4DA", "books"},
        {"📖", "U+1F4D6", "open book"},
        {"🔍", "U+1F50D", "left-pointing magnifying glass"},
        {"🔒", "U+1F512", "lock"},
        {"💡", "U+1F4A1", "electric light bulb"},
        {"🔋", "U+1F50B", "battery"},
        {"📌", "U+1F4CC", "pushpin"},
    }},
}

-- ── Build display text ──

local buf = {}
local function add_line(s)
    table.insert(buf, s)
end

add_line("Symbol  Codepoint  Name")
add_line("Missing glyphs (tofu boxes) mark unsupported symbols in the current font.")
add_line("")

for _, section in ipairs(sections) do
    add_line(string.format("── %s ──", section.title))
    for _, item in ipairs(section.items) do
        add_line(string.format("%s   %s   %s", item[1], item[2], item[3]))
    end
    add_line("")
end

local text = table.concat(buf, "\n")

-- ── Dialog ──

local dialog

local close_button = Button:new{
    text = "Close",
    callback = function()
        UIManager:close(dialog)
    end,
}

local scroll = ScrollTextWidget:new{
    text = text,
    width = Screen:scaleBySize(Screen:getWidth() * 0.88),
    height = Screen:scaleBySize(Screen:getHeight() * 0.68),
    face = Font:getFace("cfont", 24),
    alignment = "left",
}

dialog = CenterContainer:new{
    dimen = Screen:getSize(),
    FrameContainer:new{
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.default,
        VerticalGroup:new{
            align = "left",
            TitleBar:new{
                width = scroll.width,
                title = "Unicode icons",
                fullscreen = false,
                align = "left",
            },
            scroll,
            VerticalSpan:new{ width = Size.padding.small },
            close_button,
            VerticalSpan:new{ width = Size.padding.default },
        },
    },
}
scroll.dialog = dialog -- ScrollTextWidget needs this for tap/scroll refresh

UIManager:show(dialog)
UIManager:run()
