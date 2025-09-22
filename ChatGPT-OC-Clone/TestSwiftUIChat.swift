//
//  TestSwiftUIChat.swift
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant on 2024/12/19.
//  测试 SwiftUI 聊天界面的独立程序

import SwiftUI

@main
struct TestSwiftUIChatApp: App {
    var body: some Scene {
        WindowGroup {
            TestChatView()
        }
    }
}

struct TestChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    
    var body: some View {
        VStack {
            Text("SwiftUI 聊天界面测试")
                .font(.title)
                .padding()
            
            ChatListView(viewModel: viewModel)
            
            HStack {
                Button("添加用户消息") {
                    let message = ChatMessage(
                        id: UUID().uuidString,
                        content: "这是一条测试消息：\(Date())",
                        isFromUser: true,
                        timestamp: Date()
                    )
                    viewModel.addMessage(message)
                }
                
                Button("添加AI消息") {
                    let message = ChatMessage(
                        id: UUID().uuidString,
                        content: "这是AI的回复消息：\(Date())",
                        isFromUser: false,
                        timestamp: Date()
                    )
                    viewModel.addMessage(message)
                }
                
                Button("切换思考状态") {
                    viewModel.setThinking(!viewModel.isThinking)
                }
            }
            .padding()
        }
    }
}

struct TestChatView_Previews: PreviewProvider {
    static var previews: some View {
        TestChatView()
    }
}