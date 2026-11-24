require 'openssl'
require 'base64'
require 'json'
require 'net/http'

def b64(value)
  Base64.urlsafe_encode64(value, padding: false)
end

now = Time.now.to_i
header = {alg: 'ES256', kid: ENV.fetch('KEY_ID'), typ: 'JWT'}
claims = {iss: ENV.fetch('ISSUER'), iat: now, exp: now + 180, aud: 'appstoreconnect-v1'}
unsigned = [header, claims].map { |item| b64(JSON.generate(item)) }.join('.')
key = OpenSSL::PKey.read(File.read(ENV.fetch('ASC_KEY_PATH')))
signature = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(unsigned))
raw = OpenSSL::ASN1.decode(signature).value.map { |part| [part.value.to_s(16).rjust(64, '0')].pack('H*') }.join
token = "#{unsigned}.#{b64(raw)}"

def api(token, method, route, body = nil, query = {})
  uri = URI("https://api.appstoreconnect.apple.com/v1/#{route}")
  uri.query = URI.encode_www_form(query) unless query.empty?
  request = method.new(uri)
  request['Authorization'] = "Bearer #{token}"
  if body
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { |http| http.request(request) }
  parsed = response.body && !response.body.empty? ? JSON.parse(response.body) : {}
  abort "#{request.method} #{route}: HTTP #{response.code} #{parsed.fetch('errors', []).map { |e| e.slice('code','title','detail') }}" unless response.is_a?(Net::HTTPSuccess)
  parsed['data']
end

app_id = '6834716453'
number = ENV.fetch('PREVIEW_BUILD', '10')
groups = api(token, Net::HTTP::Get, "apps/#{app_id}/betaGroups")
builds = api(token, Net::HTTP::Get, 'builds', nil, {'filter[app]' => app_id, 'sort' => '-uploadedDate', 'limit' => 10})
build = builds.find { |item| item.dig('attributes', 'version') == number }
result = {build: build && {id: build['id']}.merge(build['attributes'].slice('version', 'processingState', 'expired', 'buildAudienceType'))}
result[:groups] = groups.map do |group|
  members = api(token, Net::HTTP::Get, "betaGroups/#{group['id']}/betaTesters")
  linked = api(token, Net::HTTP::Get, "betaGroups/#{group['id']}/builds")
  {id: group['id'], testerCount: members.length, builds: linked.map { |entry| entry.dig('attributes', 'version') }}.merge(group['attributes'].slice('name', 'isInternalGroup', 'hasAccessToAllBuilds', 'publicLink', 'publicLinkEnabled'))
end
if build
  result[:availability] = api(token, Net::HTTP::Get, "builds/#{build['id']}/buildBetaDetail")['attributes']
  if ENV['PREVIEW_ACTION'] == 'notes'
    notes = 'Fixes website sign-ins being lost when workspace tabs unload or iOS closes the backgrounded app. Session cookies are saved securely on this iPhone and restored before pages load. Workspaces stay separate; signing out of a website or clearing website data removes the saved session.'
    existing = api(token, Net::HTTP::Get, "builds/#{build['id']}/betaBuildLocalizations")
    english = existing.find { |entry| entry.dig('attributes', 'locale') == 'en-US' }
    if english
      api(token, Net::HTTP::Patch, "betaBuildLocalizations/#{english['id']}", {data: {type: 'betaBuildLocalizations', id: english['id'], attributes: {whatsNew: notes}}})
    else
      api(token, Net::HTTP::Post, 'betaBuildLocalizations', {data: {type: 'betaBuildLocalizations', attributes: {locale: 'en-US', whatsNew: notes}, relationships: {build: {data: {type: 'builds', id: build['id']}}}}})
    end
    result[:notesUpdated] = true
  end
end
puts JSON.generate(result)
