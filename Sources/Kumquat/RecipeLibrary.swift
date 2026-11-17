import AppKit
import SwiftUI
import KumquatCore

/// The user's recipes, reloaded whenever the recipes folder changes. Problems are logged once per change
/// and listed in Settings ▸ Recipes, so a broken recipe is never silently ignored.
@MainActor
final class RecipeLibrary: ObservableObject {
    static let shared = RecipeLibrary()

    @Published private(set) var loaded = UserRecipes.LoadResult()
    private var fingerprint: String?

    /// Current recipes, reloading first if a file changed.
    var recipes: [UserRecipe] {
        reloadIfChanged()
        return loaded.recipes
    }

    func reloadIfChanged() {
        let current = UserRecipes.fingerprint()
        guard current != fingerprint else { return }
        fingerprint = current
        loaded = UserRecipes.load()
        if !loaded.recipes.isEmpty { AppLog.info("Recipes: \(loaded.recipes.map(\.name).joined(separator: ", "))") }
        loaded.problems.forEach { AppLog.error("Recipe \($0)") }
    }

    func reload() {
        fingerprint = nil
        reloadIfChanged()
    }

    func openFolder() {
        do {
            try UserRecipes.createFolder()
            NSWorkspace.shared.open(UserRecipes.directory)
        } catch {
            NSSound.beep()
            AppLog.error("Couldn't create the recipes folder: \(error.localizedDescription)")
        }
    }
}

/// Settings ▸ Recipes.
struct RecipesSection: View {
    @ObservedObject var library = RecipeLibrary.shared

    var body: some View {
        Section {
            if library.loaded.recipes.isEmpty && library.loaded.problems.isEmpty {
                Text("No recipes yet. Open Folder creates the folder with a disabled example.")
                    .foregroundStyle(.secondary)
            }
            ForEach(library.loaded.recipes, id: \.file) { recipe in
                HStack(alignment: .top) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.name).fontWeight(.medium)
                        Text("\(recipe.from.map(\.shortName).joined(separator: ", ")) → \(recipe.to.shortName) · \(recipe.file.lastPathComponent) · stops after \(Int(recipe.timeout)) s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(library.loaded.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        } header: {
            HStack {
                Text("Recipes")
                Spacer()
                Button("Open Folder") { library.openFolder() }
                Button("Reload") { library.reload() }
            }
        }
        .onAppear { library.reloadIfChanged() }

        Section {
            Text(Self.example)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("Recipe file")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("One JSON file per recipe. {input} and {output} are replaced with file paths; the command runs directly, never through a shell, and is stopped after the timeout (seconds, at most 3600).")
                Text("Only files you own that other users can't change are loaded. Recipes run with your permissions: add only commands you trust.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private static let example = """
    {
      "name": "Markdown to PDF with my stylesheet",
      "from": ["md"],
      "to": "pdf",
      "command": ["/opt/homebrew/bin/pandoc", "{input}", "-o", "{output}"],
      "timeout": 120
    }
    """
}
