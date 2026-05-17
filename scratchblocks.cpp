#include <iostream>
#include <string>
#include <vector>
#include <map>
#include <functional>
#include <memory>
#include <algorithm>
#include <regex>
#include <chrono>
#include <thread>
#include <mutex>
#include <sstream>
#include <iomanip>

/**
 * MOCK DOM AND LIBRARY STRUCTURES
 * These classes represent the environment and external libraries (scratchblocks, CodeMirror)
 * to maintain the exact logic of the original JavaScript code.
 */

// Mock SVG class to represent rendered blocks
class SVG {
public:
    std::string className;
    void addClass(const std::string& name) { className = name; }
};

// Mock Document and View for scratchblocks
namespace scratchblocks {
    struct Language {
        std::string name;
        std::string altName;
        int percentTranslated;
        std::map<std::string, std::string> aliases;
    };

    std::map<std::string, Language> allLanguages;

    class Document {
    public:
        std::string script;
    };

    class View {
    public:
        Document doc;
        std::string style;
        double scale;

        SVG render() {
            SVG svg;
            svg.addClass("scratchblocks-style-" + style);
            return svg;
        }

        std::string exportSVG() { return "data:image/svg+xml;base64,..."; }
        void exportPNG(std::function<void(std::string)> callback, int scaleFactor) {
            callback("data:image/png;base64,...");
        }
    };

    Document parse(const std::string& script, const std::map<std::string, std::vector<std::string>>& options) {
        Document d;
        d.script = script;
        return d;
    }

    std::shared_ptr<View> newView(const Document& doc, const std::map<std::string, double>& options) {
        auto view = std::make_shared<View>();
        view->doc = doc;
        // Logic for scale based on style
        return view;
    }

    std::shared_ptr<View> newView(const Document& doc, const std::map<std::string, std::string>& options) {
        auto view = std::make_shared<View>();
        view->doc = doc;
        for (auto const& [key, val] : options) {
            if (key == "style") view->style = val;
        }
        return view;
    }
}

// Mock CodeMirror Editor
class CodeMirrorInstance {
private:
    std::string content;
    std::function<void()> changeHandler;
public:
    CodeMirrorInstance(void* element, std::map<std::string, std::string> config) {
        content = config["value"];
    }
    std::string getValue() { return content; }
    void setValue(std::string val) { content = val; }
    void setCursor(size_t pos) {}
    void setSize(int w, int h) {}
    void on(std::string event, std::function<void()> callback) {
        if (event == "change") changeHandler = callback;
    }
    void triggerChange(std::string newVal) {
        content = newVal;
        if (changeHandler) changeHandler();
    }
};

// Mock Browser Environment
struct Location {
    std::string href = "http://localhost/#";
    std::string hash = "";
};

struct History {
    void replaceState(std::string a, std::string b, std::string c) {}
};

struct Element {
    std::string innerHTML;
    std::string textContent;
    std::string value;
    std::string href;
    int clientWidth = 800;
    int clientHeight = 600;
    std::vector<std::shared_ptr<Element>> children;

    void appendChild(std::shared_ptr<Element> el) { children.push_back(el); }
    void appendChild(SVG svg) { innerHTML = "<svg>"; }
};

// Global Browser-like objects
Location location;
History history_obj;
std::map<std::string, std::shared_ptr<Element>> document_elements;

std::shared_ptr<Element> getElementById(std::string id) {
    if (document_elements.find(id) == document_elements.end()) {
        document_elements[id] = std::make_shared<Element>();
    }
    return document_elements[id];
}

// URI Encoding/Decoding helpers
std::string decodeURIComponent(std::string str) {
    std::string res;
    for (size_t i = 0; i < str.length(); ++i) {
        if (str[i] == '%' && i + 2 < str.length()) {
            std::string hex = str.substr(i + 1, 2);
            res += (char)std::stoi(hex, nullptr, 16);
            i += 2;
        } else if (str[i] == '+') {
            res += ' ';
        } else {
            res += str[i];
        }
    }
    return res;
}

std::string encodeURIComponent(std::string str) {
    std::ostringstream escaped;
    escaped.fill('0');
    escaped << std::hex;
    for (char c : str) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            escaped << c;
        } else {
            escaped << '%' << std::setw(2) << int((unsigned char)c);
        }
    }
    return escaped.str();
}

/**
 * TRANSLATED LOGIC
 */

struct AppState {
    std::string script;
    std::string lang;
    std::string style;
};

AppState obj;
std::shared_ptr<CodeMirrorInstance> codeMirror;

// Prototypes
void objUpdated();
bool extractHash();
AppState decodeHash();
void setHash(std::string hash);
void updatedFromHash();

// DOM Element References
auto editor_el = getElementById("editor");
auto exportSVGLink = getElementById("export-svg");
auto exportPNGLink = getElementById("export-png");
auto chooseLang = getElementById("choose-lang");
auto chooseStyle = getElementById("choose-style");
auto langStatus = getElementById("lang-status");
auto preview = getElementById("preview");

// Debounce implementation for C++
class Debouncer {
    std::mutex mtx;
    std::chrono::milliseconds wait;
    std::thread timer_thread;
    bool active = false;
    std::function<void()> func;

public:
    Debouncer(std::chrono::milliseconds w) : wait(w) {}
    void execute(std::function<void()> f) {
        std::lock_guard<std::mutex> lock(mtx);
        func = f;
        if (active) return;
        active = true;
        if (timer_thread.joinable()) timer_thread.detach();
        timer_thread = std::thread([this]() {
            std::this_thread::sleep_for(wait);
            std::lock_guard<std::mutex> l(mtx);
            func();
            active = false;
        });
    }
};

Debouncer changeDebouncer(std::chrono::milliseconds(250));

void init() {
    obj.style = "scratch3";
    extractHash();

    std::map<std::string, std::string> cmConfig;
    cmConfig["value"] = obj.script;
    codeMirror = std::make_shared<CodeMirrorInstance>(editor_el.get(), cmConfig);

    codeMirror->setCursor(codeMirror->getValue().length());

    codeMirror->on("change", []() {
        changeDebouncer.execute([]() {
            obj.script = codeMirror->getValue();
            objUpdated();
        });
    });

    auto onResize = []() {
        codeMirror->setSize(editor_el->clientWidth, editor_el->clientHeight);
    };
    // window.addEventListener('resize', onResize); // Logic placeholder
    onResize();

    std::vector<std::string> languageCodes;
    for (auto const& [code, lang] : scratchblocks::allLanguages) {
        languageCodes.push_back(code);
    }
    std::sort(languageCodes.begin(), languageCodes.end());

    for (auto const& code : languageCodes) {
        if (code == "en") continue;
        auto option = std::make_shared<Element>();
        option->value = code;

        auto language = scratchblocks::allLanguages[code];
        option->textContent = (!language.name.empty() && !language.altName.empty()) 
            ? language.name + " — " + language.altName 
            : (!language.name.empty() ? language.name : (!language.altName.empty() ? language.altName : code));
        
        chooseLang->appendChild(option);
    }

    // Event listener logic simulated
    auto onLangChange = [](std::string newVal) {
        if (obj.lang == newVal) return;
        obj.lang = newVal;
        objUpdated();
    };

    auto onStyleChange = [](std::string newVal) {
        if (obj.style == newVal) return;
        obj.style = newVal;
        objUpdated();
    };

    updatedFromHash();
}

/* Extract hash from location. Returns true if changed */
bool extractHash() {
    AppState newObj = decodeHash();
    if (newObj.script.empty()) {
        newObj.script = "";
        newObj.lang = obj.lang;
    }

    if (newObj.style.empty()) {
        newObj.style = !obj.style.empty() ? obj.style : "scratch3";
    }

    if (newObj.lang != obj.lang || newObj.script != obj.script || newObj.style != obj.style) {
        obj = newObj;
        return true;
    }
    return false;
}

AppState decodeHash() {
    size_t hashPos = location.href.find('#');
    if (hashPos == std::string::npos) return AppState();
    
    std::string hash = location.href.substr(hashPos + 1);
    if (hash.empty()) return AppState();

    if (hash.find('?') != 0) {
        AppState result;
        result.script = decodeURIComponent(hash);
        return result;
    } else {
        AppState newObj;
        std::string query = hash.substr(1);
        std::regex rgx("([^&=]+)=([^&=]*)");
        auto words_begin = std::sregex_iterator(query.begin(), query.end(), rgx);
        auto words_end = std::sregex_iterator();

        for (std::sregex_iterator i = words_begin; i != words_end; ++i) {
            std::smatch match = *i;
            std::string key = decodeURIComponent(match[1].str());
            std::string value = decodeURIComponent(match[2].str());
            if (key == "lang") newObj.lang = value;
            else if (key == "script") newObj.script = value;
            else if (key == "style") newObj.style = value;
        }
        return newObj;
    }
}

void setHash(std::string hash) {
    // history.replaceState sim
    history_obj.replaceState("", "", hash);
    location.hash = hash;
}

void objUpdated() {
    // set hash
    if (!obj.lang.empty() || !obj.style.empty()) {
        std::string hash = "#?";
        if (!obj.style.empty()) hash += "style=" + encodeURIComponent(obj.style) + "&";
        if (!obj.lang.empty()) hash += "lang=" + encodeURIComponent(obj.lang) + "&";
        hash += "script=" + encodeURIComponent(obj.script);
        setHash(hash);
    } else if (!obj.style.empty()) {
        setHash("#?lang=" + encodeURIComponent(obj.lang) + "&script=" + encodeURIComponent(obj.script));
    } else if (!obj.lang.empty()) {
        setHash("#?lang=" + encodeURIComponent(obj.lang) + "&script=" + encodeURIComponent(obj.script));
    } else if (!obj.script.empty()) {
        setHash("#" + encodeURIComponent(obj.script));
    } else {
        if (!(location.hash == "" || location.hash == "#")) {
            setHash("#");
        }
    }

    // render code
    std::map<std::string, std::vector<std::string>> parseOptions;
    parseOptions["languages"] = !obj.lang.empty() ? std::vector<std::string>{"en", obj.lang} : std::vector<std::string>{"en"};
    
    auto doc = scratchblocks::parse(obj.script, parseOptions);
    
    std::map<std::string, double> viewOptionsNumeric;
    std::regex s3_rgx("^scratch3($|-)");
    viewOptionsNumeric["scale"] = std::regex_search(obj.style, s3_rgx) ? 0.675 : 1.0;
    
    std::map<std::string, std::string> viewOptionsStyle;
    viewOptionsStyle["style"] = obj.style;

    auto docView = scratchblocks::newView(doc, viewOptionsStyle);
    docView->scale = viewOptionsNumeric["scale"];

    SVG svg = docView->render();
    svg.addClass("scratchblocks-style-" + obj.style);
    
    preview->innerHTML = "";
    preview->appendChild(svg);

    exportSVGLink->href = "";
    exportPNGLink->href = "";

    // add export link logic simulated with thread
    std::thread([docView]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        exportSVGLink->href = docView->exportSVG();

        docView->exportPNG([](std::string pngDataURL) {
            exportPNGLink->href = pngDataURL;
        }, 3);
    }).detach();

    // include code in scratchblocks links
    getElementById("translate-link")->href = "/translator/#" + encodeURIComponent(obj.script);

    // update language dropdown
    if (scratchblocks::allLanguages.count(obj.lang)) {
        auto lang = scratchblocks::allLanguages[obj.lang];
        langStatus->textContent = std::to_string(lang.percentTranslated) + "%";
        
        if (lang.aliases.empty()) {
            auto link = std::make_shared<Element>();
            link->href = "https://github.com/scratchblocks/scratchblocks/edit/master/locales-src/extra_aliases.js";
            link->textContent = "requires aliases";
            langStatus->textContent += ", ";
            langStatus->appendChild(link);
        }
    } else {
        langStatus->textContent = "";
    }
}

void pollingLoop() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        if (extractHash()) {
            updatedFromHash();
        }
    }
}

void updatedFromHash() {
    objUpdated();
    if (codeMirror) codeMirror->setValue(obj.script);
    chooseLang->value = !obj.lang.empty() ? obj.lang : "";
    chooseStyle->value = !obj.style.empty() ? obj.style : "";
}

int main() {
    init();
    // Simulate polling in a thread for hash changes
    std::thread poller(pollingLoop);
    poller.join();
    return 0;
}
