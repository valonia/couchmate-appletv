platform :tvos, '17.0'
use_frameworks!

target 'Couchmate' do
  # VLC plays everything the plugins can deliver (MPEG-TS live, MKV, AC3, separate video and audio files …).
  pod 'TVVLCKit', '~> 3.6'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['TVOS_DEPLOYMENT_TARGET'] = '17.0'
    end
  end
end
