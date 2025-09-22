source 'https://mirrors.tuna.tsinghua.edu.cn/git/CocoaPods/Specs.git'

platform :ios, '14.0'

target 'ChatGPT-OC-Clone' do
  use_frameworks!
  use_modular_headers!

  pod 'Texture'
  pod 'Down', :modular_headers => true
  pod 'AliyunOSSiOS'
  pod 'QCloudCOSXML/Slim'
end

post_install do |installer|
  # 统一提升 Pods 的最低部署版本
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      current = config.build_settings['IPHONEOS_DE PLOYMENT_TARGET']
      if current.nil? || current.to_f < 14.0
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0'
      end
    end
  end
end
