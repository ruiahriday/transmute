import SwiftUI

/// Settings → Customize Wheels: pick which bubbles each wheel shows for each kind of file, and
/// where. Drag a bubble onto another position to swap them, or use the list. Saves as you go.
struct WheelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var wheel: WheelKind = .convert
    @State private var kind: FileKind = .document
    @State private var slots: [String] = WheelLayout.layout(.convert, .document)
    @State private var selected: Int?
    @State private var isCustom = WheelLayout.isCustom(.convert, .document)
    @State private var confirmResetAll = false

    private static let previewSize: CGFloat = 320
    private static let radius: CGFloat = 112
    private static let slotPrefix = "transmute-wheel-slot:"

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Wheel", selection: $wheel) {
                    ForEach(WheelKind.allCases) { Text(tabTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("When I drag", selection: $kind) {
                    ForEach(FileKind.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Text("Drag a bubble onto another spot to swap them. Positions go clockwise from the top. Any format, tool or action can go on any wheel, and changes save right away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)

            HStack(alignment: .top, spacing: 16) {
                preview
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the wheel (clockwise from the top)").font(.headline)
                    List(selection: $selected) {
                        ForEach(Array(slots.enumerated()), id: \.offset) { index, id in
                            row(index, id).tag(index)
                        }
                        .onMove { from, to in
                            change(select: nil) { slots.move(fromOffsets: from, toOffset: to) }
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    addMenu
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()
            HStack {
                Button("Reset to Default") {
                    WheelLayout.reset(wheel, kind)
                    load()
                }
                .disabled(!isCustom)
                Button("Reset All Wheels…") { confirmResetAll = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 760, height: 580)
        .onChange(of: wheel) { _ in load() }
        .onChange(of: kind) { _ in load() }
        .confirmationDialog("Put every wheel back the way Transmute came?", isPresented: $confirmResetAll) {
            Button("Reset All Wheels", role: .destructive) {
                WheelLayout.saved = [:]
                load()
            }
        }
    }

    private func tabTitle(_ wheel: WheelKind) -> String {
        let name: String
        switch wheel {
        case .convert: name = "Formats"
        case .tools: name = "Tools"
        case .actions: name = "Actions"
        }
        return wheel.key == .off ? name : "\(name) (\(wheel.key.label))"
    }

    private var status: String {
        let real = slots.filter { $0 != WheelLayout.gap }.count
        if real == 0 { return "Nothing on this wheel, so it won't open for \(kind.title.lowercased())." }
        return "\(isCustom ? "Customized" : "The default wheel"). \(slots.count) of \(WheelLayout.maxSlots) spots used."
    }

    // MARK: Editing

    private func load() {
        slots = WheelLayout.layout(wheel, kind)
        isCustom = WheelLayout.isCustom(wheel, kind)
        selected = nil
    }

    private func change(select: Int?, _ edit: () -> Void) {
        edit()
        WheelLayout.save(slots, wheel, kind)
        isCustom = WheelLayout.isCustom(wheel, kind)
        selected = select
    }

    private func add(_ id: String) {
        guard slots.count < WheelLayout.maxSlots || (id != WheelLayout.gap && slots.contains(WheelLayout.gap)) else { return }
        // Into the first empty space if there is one, otherwise at the end.
        if id != WheelLayout.gap, let at = slots.firstIndex(of: WheelLayout.gap) {
            change(select: at) { slots[at] = id }
        } else {
            change(select: slots.count) { slots.append(id) }
        }
    }

    private func swap(_ from: Int, _ to: Int) {
        guard from != to, slots.indices.contains(from), slots.indices.contains(to) else { return }
        change(select: to) { slots.swapAt(from, to) }
    }

    private func unused(_ prefix: String) -> [String] {
        WheelLayout.available(kind).filter { $0.hasPrefix(prefix) && !slots.contains($0) }
    }

    // MARK: Pieces

    private var addMenu: some View {
        Menu("Add…") {
            ForEach([("Formats", "convert:"), ("Tools", "tool:"), ("Actions", "action:")], id: \.1) { title, prefix in
                let ids = unused(prefix)
                Menu(title) {
                    ForEach(ids, id: \.self) { id in
                        Button(WheelItem.describe(id)) { add(id) }
                    }
                }
                .disabled(ids.isEmpty)
            }
            Divider()
            Button("Empty space") { add(WheelLayout.gap) }
                .disabled(slots.count >= WheelLayout.maxSlots)
        }
        .fixedSize()
        .disabled(slots.count >= WheelLayout.maxSlots && !slots.contains(WheelLayout.gap))
    }

    private func row(_ index: Int, _ id: String) -> some View {
        HStack {
            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            Text(WheelItem.describe(id)).foregroundStyle(id == WheelLayout.gap ? .secondary : .primary)
            Spacer()
            Button { change(select: index - 1) { slots.swapAt(index, index - 1) } } label: { Image(systemName: "chevron.up") }
                .help("Move up (anticlockwise)")
                .disabled(index == 0)
            Button { change(select: index + 1) { slots.swapAt(index, index + 1) } } label: { Image(systemName: "chevron.down") }
                .help("Move down (clockwise)")
                .disabled(index == slots.count - 1)
            Button { change(select: nil) { slots.remove(at: index) } } label: { Image(systemName: "xmark") }
                .help("Remove from the wheel")
        }
        .buttonStyle(.borderless)
    }

    private var preview: some View {
        let size = WheelGeometry.bubbleSize(count: slots.count, radius: Self.radius, largest: 60)
        let ring: CGFloat = (Self.radius + 30 + 10) * 2
        return ZStack {
            Circle()
                .fill(Color.primary.opacity(0.04))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                .frame(width: ring, height: ring)
            Text(wheel.title).font(.headline)
            ForEach(Array(slots.enumerated()), id: \.offset) { index, id in
                bubble(index, id, size: size)
                    .offset(WheelGeometry.position(of: index, count: slots.count, radius: Self.radius))
            }
        }
        .frame(width: Self.previewSize, height: Self.previewSize)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func bubble(_ index: Int, _ id: String, size: CGFloat) -> some View {
        let item = WheelItem(id: id)
        let isSelected = selected == index
        return VStack(spacing: 2) {
            if let item {
                Image(systemName: item.symbol).font(.system(size: 14, weight: .semibold))
                Text(item.label).font(.system(size: 9, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text("empty").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Circle().fill(item == nil ? Color.clear : Color(nsColor: .windowBackgroundColor)))
        .overlay(
            Circle().strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(item == nil ? 0.35 : 0.15),
                                  style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1, dash: item == nil ? [4, 3] : []))
        )
        .shadow(radius: item == nil ? 0 : 1.5)
        .contentShape(Circle())
        .help(WheelItem.describe(id))
        .onTapGesture { selected = index }
        .draggable(Self.slotPrefix + String(index))
        .dropDestination(for: String.self) { payload, _ in
            guard let text = payload.first, text.hasPrefix(Self.slotPrefix),
                  let from = Int(text.dropFirst(Self.slotPrefix.count)) else { return false }
            swap(from, index)
            return true
        }
    }
}
