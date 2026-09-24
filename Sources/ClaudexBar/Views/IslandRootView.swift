import ClaudexCore
import SwiftUI

struct IslandRootView: View {
    let model: IslandModel
    let vm: IslandViewModel
    let actions: IslandActions

    var body: some View {
        let l = model.layout
        let g = model.geometry
        let expanded = model.mode == .expanded
        let shape = IslandShape(shoulder: l.shoulder, bottom: l.bottomRadius)

        VStack(spacing: 0) {
            BandView(vm: vm, notchWidth: g.notch.width, expanded: expanded, showRing: model.showUsageRing,
                     compact: model.metrics.earWidth < 66)
                .frame(height: g.bandHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.mode == .collapsed || expanded { actions.togglePin() }
                }

            if model.mode == .peek, let peek = model.peek {
                PeekLineView(event: peek)
                    .frame(height: model.metrics.peekLineHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { if let id = peek.sessionID { actions.activateSession(id) } else { actions.togglePin() } }
                    .id(peek.id)
                    .transition(.asymmetric(insertion: .push(from: .bottom).combined(with: .opacity),
                                            removal: .opacity))
            }

            if expanded {
                ExpandedContentView(vm: vm, metrics: model.metrics, actions: actions, pinned: model.pinned)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                            .animation(.easeOut(duration: 0.2).delay(0.07)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))))
            }
        }
        .padding(.horizontal, l.shoulder)
        .frame(width: l.bodySize.width, height: l.bodySize.height, alignment: .top)
        .clipShape(shape)
        .background(
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(l.shadowOpacity), radius: l.shadowRadius, x: 0, y: 6)
        )
        .contentShape(shape)
        .environment(\.controlActiveState, .key)
        .environment(\.forceReduceMotion, model.forceReduceMotion)
        .offset(x: model.contentOffsetX)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
