import AppKit
import SwiftUI
import KumquatCore

/// The user's recipes, reloaded whenever the recipes folder changes. Problems are logged once per change
/// and listed in Settings ▸ Engines, so a broken recipe is never silently ignored.
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

/// Settings ▸ Engines ▸ Recipes.
struct RecipesSection: View {
    @ObservedObject var library = RecipeLibrary.shared

    var body: some View {
        Section {
            if library.loaded.recipes.isEmpty && library.loaded.problems.isEmpty {
                Text("Add your own conversions: a JSON file per recipe naming the formats and the command to run. They show up on the Convert wheel. See README ▸ User recipes.")
                    .font(.caption)
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
    }
}
