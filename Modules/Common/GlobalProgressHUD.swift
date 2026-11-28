import SwiftUI

/// Global progress HUD (contract §C.7). Bound to `TaskRegistry`,
/// hidden until work exists. Shows the first active task (label +
/// percentage + cancel) and a "+N more" counter; tapping expands a
/// drawer listing every task with per-task cancel; tapping task text
/// navigates to the task's screen without interrupting it.
///
/// Phase 1 task types: certificate and profile imports (fast; the HUD
/// appears only while one is actually running). No fake tasks, no
/// simulated progress.
struct GlobalProgressHUD: View {
    @EnvironmentObject private var registry: TaskRegistry
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var expanded = false

    var body: some View {
        if !registry.tasks.isEmpty {
            VStack(spacing: DS.Spacing.md) {
                if expanded {
                    taskDrawer
                }
                hudCapsule
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.bottom, DS.Spacing.md)
            .accessibilityElement(children: .contain)
        }
    }

    private var hudCapsule: some View {
        HStack(spacing: DS.Spacing.md) {
            if let first = registry.tasks.first {
                Button {
                    navigate(to: first.destination)
                } label: {
                    HStack(spacing: DS.Spacing.md) {
                        if let progress = first.progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.circular)
                                .frame(width: 20, height: 20)
                        } else {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .frame(width: 20, height: 20)
                        }
                        Text(first.label)
                            .font(.subheadline)
                            .lineLimit(1)
                        if let progress = first.progress {
                            Text("\(Int(progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Loc.string("hud.progress", Int(progress * 100)))
                        }
                    }
                }
                .accessibilityLabel(first.label)
                Button {
                    registry.cancel(id: first.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: DS.Accessibility.minTouchTarget, minHeight: DS.Accessibility.minTouchTarget)
                }
                .accessibilityLabel(Loc.string("common.cancel"))
                if registry.tasks.count > 1 {
                    Button {
                        expanded.toggle()
                    } label: {
                        Text(Loc.string("hud.more", registry.tasks.count - 1))
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel(Loc.string("hud.more", registry.tasks.count - 1))
                }
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.xs)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 4)
    }

    private var taskDrawer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(Loc.string("hud.tasks"))
                .font(.headline)
                .accessibilityLabel(Loc.string("hud.tasks"))
            ForEach(registry.tasks) { task in
                HStack(spacing: DS.Spacing.md) {
                    Button {
                        navigate(to: task.destination)
                    } label: {
                        HStack(spacing: DS.Spacing.md) {
                            if let progress = task.progress {
                                ProgressView(value: progress)
                                    .frame(width: 20, height: 20)
                            } else {
                                ProgressView()
                                    .frame(width: 20, height: 20)
                            }
                            Text(task.label)
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityLabel(task.label)
                    Spacer()
                    Button {
                        registry.cancel(id: task.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: DS.Accessibility.minTouchTarget, minHeight: DS.Accessibility.minTouchTarget)
                    }
                    .accessibilityLabel(Loc.string("common.cancel"))
                }
            }
        }
        .padding(DS.Spacing.lg)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.cornerRadius))
        .shadow(radius: 4)
    }

    private func navigate(to destination: TaskRegistry.TaskDestination) {
        expanded = false
        switch destination {
        case .certificates:
            coordinator.openCertificatesManager()
        case .files:
            coordinator.selectTab(.files)
        case .dashboard:
            coordinator.selectTab(.dashboard)
        }
    }
}
