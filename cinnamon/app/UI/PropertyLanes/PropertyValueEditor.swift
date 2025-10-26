import SwiftUI

struct PropertyValueEditor: View {
    @Binding var value: Float
    let lane: PropertyLane

    @State private var editingValue: Float = 0
    @State private var isEditing = false

    var body: some View {
        HStack {
            if isEditing {
                TextField("Value", value: $editingValue, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { commit() }
                    .onDisappear { commit() }
            } else {
                Text(format(value: value))
                    .onTapGesture {
                        editingValue = value
                        isEditing = true
                    }
            }
            Text(lane.unit).foregroundStyle(.secondary)
        }
    }

    private func commit() {
        value = min(max(editingValue, lane.valueRange.lowerBound), lane.valueRange.upperBound)
        isEditing = false
    }

    private func format(value: Float) -> String {
        switch lane.unit {
        case "%": return String(format: "%.1f%%", value)
        case "°": return String(format: "%.1f°", value)
        default: return String(format: "%.2f", value)
        }
    }
}
