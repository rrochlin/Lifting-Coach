import LiftingCoachModel
import LiftingCoachPersistence
import SwiftUI

/// The Coach tab — send and receive, INFRA-SPEC §13.
///
/// A message shows the moment it's sent, a typing indicator holds the reply's
/// place, and anything that goes wrong is said on the message it happened to.
/// Leaving this screen loses nothing: `CoachModel`, which owns the sending,
/// lives on the environment, and a reply that lands while you're elsewhere
/// badges the tab.
struct CoachView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var draft = ""
    @FocusState private var composing: Bool
    @State private var isShowingConversations = false
    @State private var isShowingProfile = false

    private var coach: CoachModel { environment.coach }

    var body: some View {
        NavigationStack {
            Group {
                if coach.hasConsented {
                    conversation
                } else {
                    CoachConsentView { coach.consent() }
                }
            }
            .background(Theme.void)
            .navigationTitle(coach.hasConsented ? coach.currentTitle : "Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if coach.hasConsented {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isShowingConversations = true } label: {
                            Image(systemName: "list.bullet")
                        }
                        .accessibilityLabel("Conversations")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { isShowingProfile = true } label: {
                            Image(systemName: "person.text.rectangle")
                        }
                        .accessibilityLabel("What your coach knows")
                        Button { coach.startNewConversation() } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New conversation")
                    }
                }
            }
            .sheet(isPresented: $isShowingConversations) { CoachConversationList() }
            .sheet(isPresented: $isShowingProfile) { CoachProfileView() }
            #if DEBUG
            .onAppear {
                // `-openCoachProfile` / `-openCoachConversations`, for screenshots.
                let arguments = ProcessInfo.processInfo.arguments
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    if arguments.contains("-openCoachProfile") { isShowingProfile = true }
                    if arguments.contains("-openCoachConversations") { isShowingConversations = true }
                }
            }
            #endif
        }
        .onAppear {
            coach.isVisible = true
            coach.deliver()
        }
        .onDisappear { coach.isVisible = false }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if coach.messages.isEmpty {
                        emptyState
                    }
                    ForEach(coach.messages) { message in
                        CoachBubble(message: message, stopped: coach.stopped) {
                            coach.retry(message.id)
                        }
                        .id(message.id)
                    }
                    if coach.hasPending && coach.isDelivering {
                        TypingIndicator().id("typing")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            // A tap on the conversation puts the keyboard away. Simultaneous,
            // so it doesn't swallow text selection or the RETRY buttons.
            .simultaneousGesture(TapGesture().onEnded { composing = false })
            .defaultScrollAnchor(.bottom)
            .onChange(of: coach.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: coach.isDelivering) { _, _ in scrollToEnd(proxy) }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: String? = (coach.hasPending && coach.isDelivering) ? "typing" : coach.messages.last?.id
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) }
    }

    /// Says what the coach can and can't do yet, rather than an empty void —
    /// it can't see the log until 2.3, and pretending otherwise invites
    /// questions it will (rightly) decline (Core Tenets §10).
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about your training")
                .font(Theme.heading)
                .foregroundStyle(Theme.ink)
            Text(coach.memory.isEmpty
                 ? "Programming, technique, recovery, how to read a hard session. The coach learns your goals and history as you talk, and can't see your log yet — so tell it the numbers that matter."
                 : "A fresh conversation. The coach still knows your profile — tap the card icon to see what's in it.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 24)
    }

    private var canSend: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= CoachMessage.characterLimit
    }

    private var composer: some View {
        VStack(spacing: 4) {
            // How to get the keyboard out of the way, shown rather than left to
            // be discovered: a grab-handle chevron that is also the button. Part of the composer rather than a keyboard
            // toolbar — on iOS 26 that toolbar floats over the content just
            // above the keyboard, which here is the message field itself.
            if composing {
                Button {
                    composing = false
                } label: {
                    // The chevron alone — it reads as "pull down" without
                    // a caption (owner's call).
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide keyboard")
            }
            if draft.count > CoachMessage.characterLimit - 200 {
                Text("\(draft.count) / \(CoachMessage.characterLimit)")
                    .font(Theme.label)
                    .foregroundStyle(draft.count > CoachMessage.characterLimit ? Theme.alert : Theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message the coach", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composing)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.fieldEdge, lineWidth: 1))
                Button {
                    coach.send(draft)
                    draft = ""
                    // The reply takes a moment and the point is to read it;
                    // a keyboard left up covers half of where it will land.
                    composing = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? Theme.signal : Theme.inkFaint)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        #if DEBUG
        .onAppear {
            // `-focusCoachComposer`: the keyboard and its bar, for a screenshot.
            guard ProcessInfo.processInfo.arguments.contains("-focusCoachComposer") else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                composing = true
            }
        }
        #endif
    }
}

/// One message. The lifter's on the right, the coach's on the left; the
/// lifter's carry their delivery state under them until they're answered.
private struct CoachBubble: View {
    let message: CoachMessage
    let stopped: CoachOutbox.Stop?
    let onRetry: () -> Void

    private var isLifter: Bool { message.role == .lifter }

    var body: some View {
        VStack(alignment: isLifter ? .trailing : .leading, spacing: 4) {
            Text(Self.rendered(message.text))
                .font(.system(size: 16))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(isLifter ? Theme.signal.opacity(0.16) : Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isLifter ? Theme.signal.opacity(0.35) : Theme.hairline, lineWidth: 1)
                )
            status
            // What this reply changed in the profile, said where it happened —
            // the coach's one write path is never silent (INFRA-SPEC §13.7).
            ForEach(message.memoryChanges, id: \.self) { change in
                Label {
                    Text(change.summary)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: change.op == .remove ? "minus.circle" : "checkmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.signal)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isLifter ? .trailing : .leading)
        .padding(isLifter ? .leading : .trailing, 40)
    }

    @ViewBuilder
    private var status: some View {
        switch message.status {
        case .sent, .pending:
            EmptyView()
        case .pending where message.role == .lifter:
            // Said in words, not only a spinner — and honest about which kind
            // of waiting it is.
            Text(pendingText)
                .font(Theme.label)
                .tracking(1.1)
                .foregroundStyle(Theme.inkMuted)
        case .failed(let reason):
            HStack(spacing: 8) {
                Text(reason.isEmpty ? "DIDN'T SEND" : "DIDN'T SEND — \(reason.uppercased())")
                    .font(Theme.label)
                    .tracking(1.1)
                    .foregroundStyle(Theme.alert)
                    .lineLimit(2)
                Button("RETRY", action: onRetry)
                    .font(Theme.label)
                    .tracking(1.1)
                    .foregroundStyle(Theme.signal)
                    .buttonStyle(.plain)
            }
        }
    }

    /// Inline formatting only — bold, italics, code — with line breaks kept.
    /// The coach is asked for plain text and uses `**bold**` anyway; shown raw
    /// that's asterisks in the middle of advice.
    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private var pendingText: String {
        switch stopped {
        case .signInRequired: "WAITING — SIGN IN TO SEND"
        case .unavailable: "WAITING TO SEND — WILL RETRY"
        case nil: "SENT · WAITING FOR REPLY"
        }
    }
}

/// Holds the reply's place while it's being written.
private struct TypingIndicator: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.inkMuted)
                    .frame(width: 7, height: 7)
                    .phaseAnimator([0.3, 1.0]) { dot, phase in
                        dot.opacity(phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.5).delay(Double(index) * 0.15)
                    }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("The coach is replying")
    }
}

/// Apple's guideline 5.1.2(i): disclose, and ask, before personal data goes to
/// an AI model. One screen, once — and centred, like the sign-in screen.
struct CoachConsentView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 24)
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(Theme.signal)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Theme.signal.opacity(0.12)))
                .overlay(Circle().strokeBorder(Theme.signal.opacity(0.35), lineWidth: 1))
            VStack(spacing: 10) {
                Text("Talk to your coach")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Your messages are answered by Claude, an AI model from Anthropic, run through Amazon Web Services. The coach keeps notes about you — your goals, experience and constraints — which you can see and change at any time. Conversations and notes are saved on this phone and backed up with your training log.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
                Text("The coach gives advice. It never changes your plan or your log.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Button(action: onContinue) {
                Text("CONTINUE")
                    .font(Theme.label).tracking(1.2)
                    .foregroundStyle(Theme.void)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.signal)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
