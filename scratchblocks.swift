import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Models

/// Equivalent to the 'obj' object in the original JavaScript
struct ScratchObject {
    var script: String = ""
    var lang: String = ""
    var style: String = "scratch3"
}

/// Simplified representation of a Scratch Block for the native renderer
struct ScratchBlock: Identifiable {
    let id = UUID()
    let label: String
    let color: Color
    let type: BlockType
    var children: [ScratchBlock] = []
    
    enum BlockType {
        case command, hat, cap, reporter, boolean, cBlock(hasElse: Bool), end
    }
}

/// Language structure matching the scratchblocks library metadata
struct ScratchLanguage: Identifiable {
    let id: String
    let name: String
    let altName: String?
    let percentTranslated: Int
    let aliases: [String: String]
    
    var displayName: String {
        if let alt = altName {
            return "\(name) — \(alt)"
        }
        return name
    }
}

// MARK: - ScratchBlocks Utility

/// Port of the core scratchblocks library functionality (Parser & Logic)
class ScratchBlocks {
    /// Mock data representing the translations-all-v3.6.4.js library
    static let allLanguages: [String: ScratchLanguage] = [
        "en": ScratchLanguage(id: "en", name: "English", altName: nil, percentTranslated: 100, aliases: [:]),
        "de": ScratchLanguage(id: "de", name: "Deutsch", altName: "German", percentTranslated: 100, aliases: ["gehe": "move"]),
        "fr": ScratchLanguage(id: "fr", name: "Français", altName: "French", percentTranslated: 95, aliases: [:]),
        "es": ScratchLanguage(id: "es", name: "Español", altName: "Spanish", percentTranslated: 90, aliases: [:])
    ]
    
    /// Native implementation of scratchblocks.parse()
    static func parse(_ script: String, languages: [String]) -> [ScratchBlock] {
        let lines = script.components(separatedBy: .newlines)
        var blocks: [ScratchBlock] = []
        var stack: [[ScratchBlock]] = [[]]
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            // Handle C-block termination
            if trimmed.lowercased() == "end" {
                if stack.count > 1 {
                    let finishedChildren = stack.removeLast()
                    if var lastBlock = stack.last?.last {
                        var updatedBlock = lastBlock
                        updatedBlock.children = finishedChildren
                        stack[stack.count - 1].removeLast()
                        stack[stack.count - 1].append(updatedBlock)
                    }
                }
                continue
            }
            
            let type = determineType(trimmed)
            let color = determineColor(trimmed)
            let block = ScratchBlock(label: trimmed, color: color, type: type)
            
            stack[stack.count - 1].append(block)
            
            // If it's a C-block, start a new nesting level
            if case .cBlock = type {
                stack.append([])
            }
        }
        
        return stack[0]
    }
    
    private static func determineType(_ text: String) -> ScratchBlock.BlockType {
        let lower = text.lowercased()
        if lower.hasPrefix("when") { return .hat }
        if lower.hasPrefix("forever") || lower.hasPrefix("if") || lower.hasPrefix("repeat") { 
            return .cBlock(hasElse: lower.contains("else")) 
        }
        if lower.hasPrefix("stop") { return .cap }
        return .command
    }
    
    private static func determineColor(_ text: String) -> Color {
        let lower = text.lowercased()
        if lower.contains("move") || lower.contains("turn") { return Color.blue }
        if lower.contains("say") || lower.contains("think") { return Color.purple }
        if lower.contains("when") || lower.contains("broadcast") { return Color.orange }
        if lower.contains("wait") || lower.contains("forever") || lower.contains("if") { 
            return Color(red: 1.0, green: 0.6, blue: 0.0) 
        }
        return Color.gray
    }
}

// MARK: - View Model

/// Logic controller mirroring the original JavaScript script block
class ScratchViewModel: ObservableObject {
    @Published var obj = ScratchObject()
    @Published var renderedBlocks: [ScratchBlock] = []
    @Published var langStatus: String = ""
    @Published var langRequiresAliases: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private let updateSubject = PassthroughSubject<Void, Never>()
    
    init() {
        // Equivalent to the initial extractHash() call in JS
        _ = extractHash()
        
        // Debounce implementation replacing the 'debounce' JS function
        updateSubject
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.objUpdated()
            }
            .store(in: &cancellables)
        
        // Polling loop replacing setInterval(..., 200)
        Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                if self?.extractHash() == true {
                    self?.updatedFromHash()
                }
            }
            .store(in: &cancellables)
        
        updatedFromHash()
    }
    
    func onScriptChanged() {
        updateSubject.send()
    }
    
    /// Implementation of extractHash()
    func extractHash() -> Bool {
        let newObj = decodeHash()
        let oldStyle = obj.style
        let oldLang = obj.lang
        let oldScript = obj.script
        
        var updatedObj = newObj ?? ScratchObject(script: "", lang: obj.lang, style: obj.style)
        if updatedObj.style.isEmpty { updatedObj.style = oldStyle.isEmpty ? "scratch3" : oldStyle }
        
        if updatedObj.lang != oldLang || updatedObj.script != oldScript || updatedObj.style != oldStyle {
            self.obj = updatedObj
            return true
        }
        return false
    }
    
    /// Implementation of decodeHash() simulating location.hash behavior
    private func decodeHash() -> ScratchObject? {
        guard let urlString = UserDefaults.standard.string(forKey: "simulated_hash"),
              let url = URL(string: urlString),
              let fragment = url.fragment else { return nil }
        
        if !fragment.hasPrefix("?") {
            return ScratchObject(script: fragment.removingPercentEncoding ?? "", lang: obj.lang, style: obj.style)
        } else {
            var newObj = ScratchObject()
            let query = String(fragment.dropFirst())
            let parts = query.components(separatedBy: "&")
            for part in parts {
                let pair = part.components(separatedBy: "=")
                if pair.count == 2 {
                    let key = pair[0].removingPercentEncoding
                    let value = pair[1].removingPercentEncoding ?? ""
                    if key == "lang" { newObj.lang = value }
                    else if key == "script" { newObj.script = value }
                    else if key == "style" { newObj.style = value }
                }
            }
            return newObj
        }
    }
    
    /// Implementation of setHash()
    private func setHash(_ hash: String) {
        UserDefaults.standard.set("app://scratchblocks/\(hash)", forKey: "simulated_hash")
    }
    
    /// Implementation of objUpdated() - Renders blocks and updates metadata
    func objUpdated() {
        // Set simulated hash
        var hash = "#?"
        hash += "style=\(obj.style.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&"
        hash += "lang=\(obj.lang.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&"
        hash += "script=\(obj.script.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        setHash(hash)
        
        // Render blocks using the native engine
        let languages = obj.lang.isEmpty ? ["en"] : ["en", obj.lang]
        self.renderedBlocks = ScratchBlocks.parse(obj.script, languages: languages)
        
        // Update language status info
        if !obj.lang.isEmpty, let langData = ScratchBlocks.allLanguages[obj.lang] {
            self.langStatus = "\(langData.percentTranslated)%"
            self.langRequiresAliases = langData.aliases.isEmpty
        } else {
            self.langStatus = ""
            self.langRequiresAliases = false
        }
    }
    
    /// Implementation of updatedFromHash()
    func updatedFromHash() {
        objUpdated()
    }
}

// MARK: - UI Components

/// A recursive view that renders Scratch blocks natively in SwiftUI
struct ScratchBlockView: View {
    let block: ScratchBlock
    let style: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(block.label)
                    .font(.system(size: style.hasPrefix("scratch3") ? 12 : 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .background(block.color)
            .clipShape(BlockShape(type: block.type))
            
            if !block.children.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(block.children) { child in
                        ScratchBlockView(child: child, style: style)
                            .padding(.leading, 15)
                    }
                    // Bottom cap for C-blocks
                    HStack {
                        Spacer().frame(width: 30, height: 10)
                    }
                    .background(block.color)
                    .clipShape(BlockShape(type: .end))
                }
            }
        }
    }
}

/// Custom Shape for Scratch Block geometry (Hats, Commands, C-Blocks)
struct BlockShape: Shape {
    let type: ScratchBlock.BlockType
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch type {
        case .hat:
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: 15))
            path.addQuadCurve(to: CGPoint(x: rect.width, y: 15), control: CGPoint(x: rect.width/2, y: -10))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.closeSubpath()
        case .cBlock, .command, .end:
            path.addRect(rect)
        default:
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
        }
        return path
    }
}

// MARK: - Main View

/// The main interface mirroring the HTML/CSS structure of the homepage
struct ContentView: View {
    @StateObject private var viewModel = ScratchViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header (equivalent to <h1> and its links)
            headerView
            
            GeometryReader { geo in
                HStack(alignment: .top, spacing: 0) {
                    // Side panel (equivalent to #side)
                    sidebarView
                        .frame(width: geo.size.width > 600 ? 300 : geo.size.width * 0.4)
                    
                    Divider()
                    
                    // Main Editor and Preview Area
                    VStack(alignment: .leading, spacing: 0) {
                        // Editor (equivalent to #editor / CodeMirror)
                        editorView
                            .frame(height: geo.size.height * 0.4)
                        
                        Divider()
                        
                        // Preview (equivalent to #preview)
                        previewView
                    }
                }
            }
        }
        .background(Color.white)
    }
    
    var headerView: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(alignment: .bottom) {
                    Text("scratchblocks")
                        .font(.title)
                        .bold()
                        .foregroundColor(.blue)
                    Text("v3.6.4 • by blob8108")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            Spacer()
            HStack(spacing: 15) {
                Link("help", destination: URL(string: "https://en.scratch-wiki.info/wiki/Block_Plugin/Syntax")!)
                Link("github", destination: URL(string: "http://github.com/tjvr/scratchblocks")!)
                Link("translate", destination: URL(string: "https://scratchblocks.github.io/translator/#" + (viewModel.obj.script.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))!)
                Link("generate", destination: URL(string: "https://scratchblocks.github.io/generator/")!)
            }
            .font(.subheadline)
            .bold()
        }
        .padding()
        .background(Color(white: 0.95))
    }
    
    var sidebarView: some View {
        VStack(alignment: .leading, spacing: 15) {
            // Style Selector (equivalent to #choose-style)
            Picker("Style", selection: $viewModel.obj.style) {
                Text("Scratch 2.0").tag("scratch2")
                Text("Scratch 3.0").tag("scratch3")
                Text("Scratch 3.0 (high-contrast)").tag("scratch3-high-contrast")
            }
            .pickerStyle(.menu)
            .onChange(of: viewModel.obj.style) { _ in viewModel.objUpdated() }
            
            // Language Selector (equivalent to #choose-lang)
            Picker("Language", selection: $viewModel.obj.lang) {
                Text("Select language…").tag("")
                ForEach(Array(ScratchBlocks.allLanguages.keys).sorted(), id: \.self) { code in
                    if code != "en" {
                        Text(ScratchBlocks.allLanguages[code]?.displayName ?? code).tag(code)
                    }
                }
            }
            .pickerStyle(.menu)
            .onChange(of: viewModel.obj.lang) { _ in viewModel.objUpdated() }
            
            // Language Status (equivalent to #lang-status)
            HStack {
                Text(viewModel.langStatus)
                    .font(.caption)
                if viewModel.langRequiresAliases {
                    Text(", ")
                    Link("requires aliases", destination: URL(string: "https://github.com/scratchblocks/scratchblocks/edit/master/locales-src/extra_aliases.js")!)
                        .font(.caption)
                }
            }
            
            Spacer()
            
            // Export Links (equivalent to #export-svg / #export-png)
            VStack(spacing: 10) {
                Button("Export SVG") {
                    // In a production app, this would use an SVG generator logic
                }
                .buttonStyle(.bordered)
                
                Button("Export PNG") {
                    // Logic to export PNG using SwiftUI's ImageRenderer
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
    }
    
    var editorView: some View {
        TextEditor(text: $viewModel.obj.script)
            .font(.system(.body, design: .monospaced))
            .padding(4)
            .onChange(of: viewModel.obj.script) { _ in
                viewModel.onScriptChanged()
            }
    }
    
    var previewView: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.renderedBlocks) { block in
                    ScratchBlockView(block: block, style: viewModel.obj.style)
                }
            }
            .padding()
            // Mirroring the scale logic from objUpdated in JS
            .scaleEffect(viewModel.obj.style.hasPrefix("scratch3") ? 0.675 : 1.0)
        }
        .background(Color(white: 0.98))
    }
}

// MARK: - App Entry Point

@main
struct ScratchBlocksApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
