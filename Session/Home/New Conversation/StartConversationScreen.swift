// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct StartConversationScreen: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(
                    alignment: .leading,
                    spacing: Values.smallSpacing
                ) {
                    VStack(
                        alignment: .center,
                        spacing: 0
                    ) {
                        NewConversationCell(
                            image: "Message",
                            title: "vc_create_private_chat_title".localized()
                        ) {
                            
                        }
                        
                        Line(color: .borderSeparator)
                            .padding(.leading, 38 + Values.smallSpacing)
                            .padding(.trailing, -Values.largeSpacing)
                        
                        NewConversationCell(
                            image: "Group",
                            title: "vc_create_closed_group_title".localized()
                        ) {
                            
                        }
                        
                        Line(color: .borderSeparator)
                            .padding(.leading, 38 + Values.smallSpacing)
                            .padding(.trailing, -Values.largeSpacing)
                        
                        NewConversationCell(
                            image: "Globe",
                            title: "vc_join_public_chat_title".localized()
                        ) {
                            
                        }
                        
                        Line(color: .borderSeparator)
                            .padding(.leading, 38 + Values.smallSpacing)
                            .padding(.trailing, -Values.largeSpacing)
                        
                        NewConversationCell(
                            image: "icon_invite",
                            title: "vc_settings_invite_a_friend_button_title".localized()
                        ) {
                            
                        }
                    }
                    .padding(.bottom, Values.mediumSpacing)
                    
                    Text("your_account_id".localized())
                        .font(.system(size: Values.mediumLargeFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                    
                    Text("account_id_qr_code_explanation".localized())
                        .font(.system(size: Values.verySmallFontSize))
                        .foregroundColor(themeColor: .textSecondary)
                    
                    QRCodeView(
                        string: getUserHexEncodedPublicKey(),
                        hasBackground: false,
                        logo: "SessionWhite40",
                        themeStyle: ThemeManager.currentTheme.interfaceStyle
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.vertical, Values.smallSpacing)
                }
                .padding(.all, Values.largeSpacing)
            }
        }
        .backgroundColor(themeColor: .backgroundSecondary)
    }
}

fileprivate struct NewConversationCell: View {
    let image: String
    let title: String
    let action: () -> ()
    
    var body: some View {
        HStack(
            alignment: .center,
            spacing: Values.smallSpacing
        ) {
            ZStack(alignment: .center) {
                Image(image)
                    .renderingMode(.template)
                    .foregroundColor(themeColor: .textPrimary)
                    .frame(width: 25, height: 24, alignment: .bottom)
            }
            .frame(width: 38, height: 38, alignment: .leading)
            
            Text(title)
                .font(.system(size: Values.mediumLargeFontSize))
                .foregroundColor(themeColor: .textPrimary)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
        }
        .frame(height: 55)
        .onTapGesture {
            action()
        }
    }
}

#Preview {
    StartConversationScreen()
}
