# App Store の「製品ページのヘッダ」「検索結果」クリエイティブアセットを
# App Store Connect API で Asset Library にアップロードし、指定バージョンの
# ローカライズに配置する。deliver が未対応のため独自実装。
#
# 使い方:
#   ruby fastlane/scripts/upload_creative_assets.rb <bundle_id> <version> [platform]
#   例: ruby fastlane/scripts/upload_creative_assets.rb com.himatsubu.Seekthea 1.5.0 IOS
#
# 画像の置き場: fastlane/creative_assets/<locale>/header_21x9.png, search_3x2.png
#   - header_21x9.png : 3840x1646 PNG（透過なし）→ PRODUCT_PAGE_HEADER_ASSET
#   - search_3x2.png  : 1920x1280〜3840x2560 PNG/JPEG（透過なし）→ APP_STORE_SEARCH_RESULTS_ASSET
#   ファイルが無い掲載タイプはスキップする。
#
# 認証: fastlane/api_key.json（key_id / issuer_id / key）または
#       環境変数 APP_STORE_CONNECT_API_KEY_KEY_ID / _ISSUER_ID / _KEY
#
# 注意: 配置は編集不可のため、同タイプの既存配置を削除してから作り直す。
#       配置はバージョンと一緒に審査される（表示は iOS 27 / iPadOS 27 以降）。

require 'json'
require 'openssl'
require 'base64'
require 'net/http'
require 'uri'

BASE = 'https://api.appstoreconnect.apple.com/v1'
FASTLANE_DIR = File.expand_path('..', __dir__)
ASSET_FILES = {
  'PRODUCT_PAGE_HEADER_ASSET'      => 'header_21x9.png',
  'APP_STORE_SEARCH_RESULTS_ASSET' => 'search_3x2.png',
}.freeze

def api_key
  @api_key ||= if ENV['APP_STORE_CONNECT_API_KEY_KEY_ID']
    { 'key_id' => ENV['APP_STORE_CONNECT_API_KEY_KEY_ID'],
      'issuer_id' => ENV['APP_STORE_CONNECT_API_KEY_ISSUER_ID'],
      'key' => ENV['APP_STORE_CONNECT_API_KEY_KEY'] }
  else
    path = File.join(FASTLANE_DIR, 'api_key.json')
    abort "API key not found: #{path}" unless File.exist?(path)
    JSON.parse(File.read(path))
  end
end

def b64(s) = Base64.urlsafe_encode64(s, padding: false)

def token
  now = Time.now.to_i
  header = { alg: 'ES256', kid: api_key['key_id'], typ: 'JWT' }
  payload = { iss: api_key['issuer_id'], iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }
  signing = "#{b64(header.to_json)}.#{b64(payload.to_json)}"
  der = OpenSSL::PKey::EC.new(api_key['key']).sign(OpenSSL::Digest::SHA256.new, signing)
  r, s = OpenSSL::ASN1.decode(der).value.map { |i| i.value.to_s(2).rjust(32, "\0") }
  "#{signing}.#{b64(r + s)}"
end

def request(method, path, body = nil)
  uri = URI("#{BASE}/#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  klass = { 'GET' => Net::HTTP::Get, 'POST' => Net::HTTP::Post,
            'PATCH' => Net::HTTP::Patch, 'DELETE' => Net::HTTP::Delete }.fetch(method)
  req = klass.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Content-Type'] = 'application/json'
  req.body = body.to_json if body
  res = http.request(req)
  parsed = begin
    JSON.parse(res.body)
  rescue StandardError
    res.body
  end
  [res.code.to_i, parsed]
end

def request!(method, path, body = nil, expect: 200)
  code, parsed = request(method, path, body)
  abort "#{method} #{path} -> #{code}: #{parsed.inspect[0, 600]}" unless code == expect
  parsed
end

# --- アップロード ---------------------------------------------------------

def upload_image(app_id, file)
  data = File.binread(file)
  img = request!('POST', 'appAssetLibraryImages', {
    data: { type: 'appAssetLibraryImages',
            attributes: { category: 'CREATIVE_ASSETS', fileName: File.basename(file), fileSize: data.bytesize },
            relationships: { assetLibrary: { data: { type: 'appAssetLibraries', id: app_id } } } }
  }, expect: 201)['data']
  id = img['id']
  ops = img.dig('attributes', 'uploadOperations')
  puts "  予約 #{id}（#{ops.size} パート）"
  ops.each do |op|
    uri = URI(op['url'])
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP.const_get(op['method'].capitalize).new(uri)
    op['requestHeaders'].each { |h| req[h['name']] = h['value'] }
    req.body = data.byteslice(op['offset'], op['length'])
    res = http.request(req)
    abort "パートのアップロード失敗 #{res.code}: #{res.body[0, 200]}" unless res.code.to_i.between?(200, 299)
  end
  request!('PATCH', "appAssetLibraryImages/#{id}",
           { data: { type: 'appAssetLibraryImages', id: id, attributes: { uploaded: true } } })
  wait_processed(id)
end

# 処理完了は imageAsset（幅・高さ）が入ることで判定する。state は PREPARE_FOR_SUBMISSION のまま
def wait_processed(id)
  36.times do
    a = request!('GET', "appAssetLibraryImages/#{id}")['data']['attributes']
    asset = a['imageAsset']
    if asset && asset['width']
      puts "  処理完了 #{asset['width']}x#{asset['height']} spec=#{a['specId']}"
      return id
    end
    abort "処理失敗: #{a['stateDetails'].inspect}" if a['state'].to_s =~ /FAIL|REJECT/
    sleep 5
  end
  abort 'アセット処理がタイムアウトしました'
end

# --- メイン ---------------------------------------------------------------

bundle_id, version, platform = ARGV
platform ||= 'IOS'
abort "usage: #{$PROGRAM_NAME} <bundle_id> <version> [IOS|MAC_OS|VISION_OS]" unless bundle_id && version

app = request!('GET', "apps?filter[bundleId]=#{bundle_id}")['data'].first
abort "アプリが見つかりません: #{bundle_id}" unless app
app_id = app['id']

ver = request!('GET', "apps/#{app_id}/appStoreVersions?filter[platform]=#{platform}&filter[versionString]=#{version}&fields[appStoreVersions]=versionString,appStoreState")['data'].first
abort "バージョンが見つかりません: #{version} (#{platform})" unless ver
puts "バージョン #{version} #{platform}: #{ver.dig('attributes', 'appStoreState')}"

locs = request!('GET', "appStoreVersions/#{ver['id']}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale")['data']

locs.each do |loc|
  locale = loc.dig('attributes', 'locale')
  dir = File.join(FASTLANE_DIR, 'creative_assets', locale)
  next unless Dir.exist?(dir)

  puts "== #{locale}"
  placements = request!('GET', "appStoreVersionLocalizations/#{loc['id']}/placements?limit=200")['data']

  ASSET_FILES.each do |ptype, name|
    file = File.join(dir, name)
    next unless File.exist?(file)

    puts "-- #{ptype} <- #{File.basename(file)}"
    placements.select { |p| p.dig('attributes', 'placementType') == ptype }.each do |p|
      request!('DELETE', "appAssetLibraryPlacements/#{p['id']}", expect: 204)
      puts "  既存の配置を削除 #{p['id']}"
    end
    image_id = upload_image(app_id, file)
    created = request!('POST', 'appAssetLibraryPlacements', {
      data: { type: 'appAssetLibraryPlacements',
              attributes: { placementType: ptype, placementGroup: 'DEFAULT_PROFILE' },
              relationships: {
                appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: loc['id'] } },
                image: { data: { type: 'appAssetLibraryImages', id: image_id } } } }
    }, expect: 201)['data']
    puts "  配置作成 #{created['id']} state=#{created.dig('attributes', 'state')}"
  end
end
puts '完了'
