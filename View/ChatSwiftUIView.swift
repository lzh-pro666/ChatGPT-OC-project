//
//  ChatSwiftUIView.swift
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant on 2024/12/19.
//

import SwiftUI
import UIKit

// MARK: - Message Model
@objc public class ChatMessage: NSObject {
    @objc public let id: String
    @objc public let content: String
    @objc public let isFromUser: Bool
    @objc public let timestamp: Date
    
    @objc public init(id: String, content: String, isFromUser: Bool, timestamp: Date) {
        self.id = id
        self.content = content
        self.isFromUser = isFromUser
        self.timestamp = timestamp
        super.init()
    }
}

// MARK: - View Model
@MainActor
@objc public class ChatViewModel: NSObject, ObservableObject {
    @Published public var messages: [ChatMessage] = []
    @Published public var isInteracting: Bool = false
    @Published public var typingText: String = ""
    @Published public var isThinking: Bool = false
    
    // 流式更新优化：缓存和阈值机制
    private var streamingBuffer: String = ""
    private var lastUIUpdateLength: Int = 0
    private static let kStreamingThreshold: Int = 64 // 64字符阈值
    
    @objc public override init() {
        super.init()
    }
    
    @objc public func addMessage(_ message: ChatMessage) {
        self.messages.append(message)
    }
    
    @objc public func removeMessage(at index: Int) {
        if index < self.messages.count {
            self.messages.remove(at: index)
        }
    }
    
    @objc public func updateLastMessageWithContent(_ content: String) {
        if !self.messages.isEmpty && !self.messages.last!.isFromUser {
            let lastMessage = self.messages.last!
            let updatedMessage = ChatMessage(
                id: lastMessage.id,
                content: content,
                isFromUser: lastMessage.isFromUser,
                timestamp: lastMessage.timestamp
            )
            self.messages[self.messages.count - 1] = updatedMessage
        }
    }
    
    @objc public func setInteracting(_ interacting: Bool) {
        self.isInteracting = interacting
        if !interacting {
            // 交互结束时清空缓存
            streamingBuffer = ""
            lastUIUpdateLength = 0
        }
    }
    
    @objc public func setThinking(_ thinking: Bool) {
        self.isThinking = thinking
    }
    
    @objc public func startStreamingResponseFor(_ userMessage: String) {
        // 添加用户消息
        let userMsg = ChatMessage(
            id: UUID().uuidString,
            content: userMessage,
            isFromUser: true,
            timestamp: Date()
        )
        self.messages.append(userMsg)
        
        // 添加空的 AI 消息用于流式更新
        let aiMsg = ChatMessage(
            id: UUID().uuidString,
            content: "",
            isFromUser: false,
            timestamp: Date()
        )
        self.messages.append(aiMsg)
        
        // 重置流式缓存
        streamingBuffer = ""
        lastUIUpdateLength = 0
        
        // 设置交互状态
        self.isInteracting = true
    }
    
    @objc public func updateStreamingResponse(_ content: String) {
        guard !self.messages.isEmpty && !self.messages.last!.isFromUser else { return }
        
        // 更新缓存
        streamingBuffer = content
        
        // 检查是否达到更新阈值或流式结束
        let contentGrowth = content.count - lastUIUpdateLength
        let shouldUpdate = contentGrowth >= Self.kStreamingThreshold || 
                          !self.isInteracting || 
                          content.hasSuffix("\n") // 换行时立即更新
        
        if shouldUpdate {
            let lastMessage = self.messages.last!
            let updatedMessage = ChatMessage(
                id: lastMessage.id,
                content: content,
                isFromUser: false,
                timestamp: lastMessage.timestamp
            )
            self.messages[self.messages.count - 1] = updatedMessage
            lastUIUpdateLength = content.count
        }
    }
    
    @objc public func finishStreamingResponse() {
        // 确保最后的内容被更新到UI
        if !streamingBuffer.isEmpty && streamingBuffer.count > lastUIUpdateLength {
            updateStreamingResponse(streamingBuffer)
        }
        
        self.isInteracting = false
        streamingBuffer = ""
        lastUIUpdateLength = 0
    }
    
    @objc public func clearMessages() {
        self.messages.removeAll()
        streamingBuffer = ""
        lastUIUpdateLength = 0
    }
}

// MARK: - SwiftUI Views

// 优化的思考视图，增加默认高度以提升稳定性
public struct ThinkingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var animationOffset: CGFloat = 0
    
    // 增加默认最小高度，避免视图闪烁
    private let minimumHeight: CGFloat = 60
    
    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                // 思考指示文字
                Text("AI正在思考...")
                    .font(.caption)
                    .foregroundColor(colorScheme == .light ? .gray : .white.opacity(0.7))
                
                // 动画圆点
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(colorScheme == .light ? Color.gray : Color.white)
                            .frame(width: 8, height: 8)
                            .offset(y: animationOffset)
                            .animation(
                                Animation.easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.2),
                                value: animationOffset
                            )
                    }
                }
            }
            .padding(16) // 增加内边距以提升视觉稳定性
            .frame(minHeight: minimumHeight) // 设置最小高度
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorScheme == .light ? Color.gray.opacity(0.1) : Color(red: 52/255, green: 53/255, blue: 65/255))
            )
            .frame(maxWidth: UIScreen.main.bounds.width * 0.7, alignment: .leading)
            
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8) // 增加垂直边距
        .onAppear {
            animationOffset = -3
        }
        .transition(.asymmetric(
            insertion: .scale.combined(with: .opacity),
            removal: .scale.combined(with: .opacity)
        ))
    }
}

public struct MessageRowView: View {
    let message: ChatMessage
    @Environment(\.colorScheme) private var colorScheme
    @State private var cachedAttributedText: AttributedString?
    @State private var lastContentLength: Int = 0
    
    public var body: some View {
        VStack(spacing: 0) {
            messageRow(isFromUser: message.isFromUser, content: message.content)
        }
        .onAppear {
            updateAttributedTextIfNeeded()
        }
        .onChange(of: message.content) { newContent in
            updateAttributedTextIfNeeded()
        }
    }
    
    private func updateAttributedTextIfNeeded() {
        // 增量更新：只有当内容增长超过一定长度时才重新创建 AttributedString
        let contentLength = message.content.count
        let growthThreshold = 32 // 32字符增长阈值
        
        if cachedAttributedText == nil || 
           contentLength - lastContentLength >= growthThreshold ||
           contentLength < lastContentLength { // 内容减少时（如编辑）
            cachedAttributedText = createAttributedString(from: message.content)
            lastContentLength = contentLength
        } else if contentLength > lastContentLength {
            // 增量拼接：仅添加新的文本部分
            let newPart = String(message.content.dropFirst(lastContentLength))
            if let existing = cachedAttributedText {
                cachedAttributedText = existing + AttributedString(newPart)
            } else {
                cachedAttributedText = createAttributedString(from: message.content)
            }
            lastContentLength = contentLength
        }
    }
    
    private func createAttributedString(from text: String) -> AttributedString {
        var attributedString = AttributedString(text)
        
        // 基础样式
        attributedString.font = .body
        attributedString.foregroundColor = message.isFromUser ? 
            .white : (colorScheme == .light ? .black : .white)
        
        return attributedString
    }
    
    func messageRow(isFromUser: Bool, content: String) -> some View {
        HStack {
            if isFromUser {
                Spacer(minLength: 60) // 用户消息左侧留空
            }
            
            VStack(alignment: isFromUser ? .trailing : .leading) {
                if !content.isEmpty {
                    // 使用 AttributedString 提升性能
                    if let attributedText = cachedAttributedText {
                        Text(attributedText)
                            .multilineTextAlignment(isFromUser ? .trailing : .leading)
                            .textSelection(.enabled)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(isFromUser ? 
                                        Color.blue : 
                                        (colorScheme == .light ? Color.gray.opacity(0.1) : Color(red: 52/255, green: 53/255, blue: 65/255))
                                    )
                            )
                    } else {
                        // 降级到普通 Text 作为备用
                        Text(content)
                            .multilineTextAlignment(isFromUser ? .trailing : .leading)
                            .textSelection(.enabled)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(isFromUser ? 
                                        Color.blue : 
                                        (colorScheme == .light ? Color.gray.opacity(0.1) : Color(red: 52/255, green: 53/255, blue: 65/255))
                                    )
                            )
                            .foregroundColor(isFromUser ? .white : (colorScheme == .light ? .black : .white))
                    }
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.85, alignment: isFromUser ? .trailing : .leading)
            
            if !isFromUser {
                Spacer(minLength: 60) // AI消息右侧留空
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// 优化的聊天列表视图，移除自动滚动功能
public struct ChatListView: View {
    @ObservedObject var viewModel: ChatViewModel
    
    @MainActor
    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.messages, id: \.id) { message in
                            MessageRowView(message: message)
                        }
                        
                        // 显示思考视图
                        if viewModel.isThinking {
                            ThinkingView()
                                .id("thinking")
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .bottom).combined(with: .opacity)
                                ))
                        }
                        
                        // 底部标识
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(UIColor.systemBackground))
    }
}

// 已移除自动滚动功能后，删除不再使用的 PreferenceKey
// struct ScrollOffsetPreferenceKey: @preconcurrency PreferenceKey {
//     @MainActor static var defaultValue: CGFloat = 0
//     static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
//         value = nextValue()
//     }
// }

// MARK: - UIHostingController Wrapper for Objective-C
@objc public class ChatSwiftUIViewWrapper: UIViewController {
    private var hostingController: UIHostingController<ChatListView>
    @objc public let viewModel: ChatViewModel
    
    @objc public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        self.hostingController = UIHostingController(rootView: ChatListView(viewModel: viewModel))
        super.init(nibName: nil, bundle: nil)
        setupHostingController()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupHostingController() {
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        hostingController.didMove(toParent: self)
        hostingController.view.backgroundColor = .clear
    }
    
    @objc public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
    }
    
    @objc public func scrollToBottomWithAnimated(_ animated: Bool) {
        Task { @MainActor in
            // 通过 SwiftUI 的 .onChange 触发滚动
            if animated {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            } else {
                // 非动画方式：无需额外处理
            }
        }
    }
}

// MARK: - Bridge for Objective-C
@objc public class ChatSwiftUIView: NSObject {
    @MainActor
    @objc public static func createWrapper(with viewModel: ChatViewModel) -> ChatSwiftUIViewWrapper {
        return ChatSwiftUIViewWrapper(viewModel: viewModel)
    }
    
    @MainActor @objc public static func createViewModel() -> ChatViewModel {
        return ChatViewModel()
    }
}
