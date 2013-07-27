require 'net/http'
require 'net/https'
require 'nokogiri'
require 'uri'
require 'yaml'
require 'open3'

FILE_LOGIN = 'quest_login.yaml'
FILE_SHOPPING_LIST = 'quest_shopping_list.yaml'
TERM='1139'

PATH_LOGIN = '/psp/SS/?cmd=login&languageCd=ENG'
PATH_ADD_COURSES = "/psc/SS/ACADEMIC/SA/c/SA_LEARNER_SERVICES.SSR_SSENRL_CART.GBL?Page=SSR_SSENRL_CART&Action=A&ACAD_CAREER=UG&EMPLID=20392250&INSTITUTION=UWATR&STRM=#{TERM}&TargetFrameName=None"

def get_html (http, location, headers={})
  resp = http.get(location, headers)

  if resp['location'].nil?
    resp.body
  else
    get_html(http, resp['location'])
  end
end

def do_login (user, pass)
  http = Net::HTTP.new('quest.pecs.uwaterloo.ca', 443)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE

  # POST request -> logging in
  puts '>>> Authenticating with quest...'
  postdata = "timezoneOffset=240&httpPort=&userid=#{user}&pwd=#{pass}&submit=Sign in"
  headers = {'Content-Type' => 'application/x-www-form-urlencoded'}
  resp = http.post(PATH_LOGIN, postdata, headers)

  headers = {'Cookie' => resp['set-cookie']}

  # Output on the screen -> we should get either a 302 redirect (after a successful login) or an error page
  if resp.key? 'respondingwithsignonpage'
    html = get_html(http, URI.parse(resp['location']).request_uri(), headers)
    doc = Nokogiri::HTML(html)
    puts '!!! Login failed with message: ' + doc.css('.signInTable .PSERRORTEXT').text
    exit false
  end

  puts '>>> Login success'

  return http, headers
end

def get_shopping_list(http, headers)
  puts '>>> Retrieving "add class" page...'

  add_html = get_html(http, PATH_ADD_COURSES, headers)
  add_doc = Nokogiri::HTML(add_html)

  puts '>>> Parsing shopping list...'

  shop_list = {}
  add_doc.css("table[id='SSR_REGFORM_VW$scroll$0'] tr[valign='center']").each do |row|
    course_id = row.css("span[title='View Details']").text.gsub(/\r/,'')
    shop_list[course_id] = {
      'is_open' => row.css('img').to_html().include?('STATUS_OPEN'),
      'is_lecture' => !row.css('a').empty?,
      'schedule' => row.css("span[id^='DERIVED_REGFRM1_SSR_MTG_SCHED_LONG']").text,
      'instructor' => row.css("span[id^='DERIVED_REGFRM1_SSR_INSTR_LONG']").text,
      'location' => row.css("span[id^='DERIVED_REGFRM1_SSR_MTG_LOC_LONG']").text
    }
  end

  shop_list
end

quest_login = YAML.load_file(FILE_LOGIN)

http, headers = do_login quest_login['user'], quest_login['pass']
shop_list = get_shopping_list http, headers

begin
  puts '>>> Checking for changes...'

  old_shop_list = YAML.load_file(FILE_SHOPPING_LIST)

  diff = ''

  shop_list.each do |k, v|
    if old_shop_list.has_key? k
      old_v = old_shop_list[k]
      diff << "#{k}\n-#{old_v}\n+#{v}\n" if old_v != v
    else
      diff << "#{k}\n+#{v}\n"
    end
  end

  old_shop_list.each do |k, v|
    diff << "#{k}\n-#{v}\n" unless shop_list.has_key? k
  end

  unless diff.empty?
    stdin, stdout, stderr = Open3.popen3("mail -s \"Quest Courses Alert\" #{quest_login['email']}")
    stdin.puts diff
    stdin.close
  end
rescue SystemCallError => err
  puts err
end

puts '>>> Saving new shopping list...'

File.open(FILE_SHOPPING_LIST, "w") do |file|
  file.puts YAML::dump(shop_list)
end
