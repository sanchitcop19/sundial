import SwiftUI
import SundialCore

/// The rule list, in the order they are applied. Order is visible and editable
/// because "which rule won" is the first question when a verdict looks wrong.
struct RulesView: View {
    @EnvironmentObject var engine: Engine
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rules are checked top to bottom")
                        .font(.system(size: 19, weight: .semibold))
                    Text("The first one that matches decides. New rules are placed by how "
                         + "specific they are, so a broad rule cannot swallow a precise one.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if let title = engine.undoTitle {
                    Button { engine.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .help("Undo: \(title)")
                }
                Button { adding = true } label: { Label("Add", systemImage: "plus") }
            }

            if engine.rules.rules.isEmpty {
                Card {
                    Text("No rules yet. Correct something on the Today screen, or work through "
                         + "the Review list, and rules will be written for you.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                List {
                    ForEach(engine.rules.rules) { rule in
                        row(rule)
                    }
                    .onMove { engine.moveRules(from: $0, to: $1) }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .background(Theme.canvas)
        .sheet(isPresented: $adding) {
            ManualRuleView { rule in engine.add(rule); adding = false } onCancel: { adding = false }
        }
    }

    private func row(_ rule: Rule) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { engine.setEnabled($0, ruleId: rule.id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)

            RoundedRectangle(cornerRadius: 2)
                .fill(rule.outcome.state.color)
                .frame(width: 4, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                Text(rule.describe).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(rule.outcome.label)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(rule.outcome.state.color.opacity(0.18))
                .clipShape(Capsule())
            Button {
                engine.remove(ruleId: rule.id)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Hand-written rules, for cases the correction ladder does not cover.
struct ManualRuleView: View {
    var onAdd: (Rule) -> Void
    var onCancel: () -> Void

    @State private var name = ""
    @State private var field: Condition.Field = .host
    @State private var op: Condition.Op = .hostOrSubdomain
    @State private var value = ""
    @State private var outcome: Outcome = .work

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New rule").font(.system(size: 15, weight: .semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("Company wiki"))
                Picker("When", selection: $field) {
                    ForEach(Condition.Field.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Test", selection: $op) {
                    ForEach(Condition.Op.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("Value", text: $value)
                Picker("Counts as", selection: $outcome) {
                    ForEach(Outcome.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add") {
                    let n = name.isEmpty ? "\(field.rawValue) \(value)" : name
                    onAdd(Rule(name: n, conditions: [Condition(field, op, value)],
                               outcome: outcome, origin: .manual))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 430)
    }
}
