class Issue < Sequel::Model(:comic_issues)
  many_to_one :comic

  def previous_issue
    id - 1
  end

  def next_issue
    if Issue.last.id == id
      1
    else
      id + 1
    end
  end

  def save_image(file)
    filename = SecureRandom.hex(10) + ".png"

    File.open("public/#{filename}", "wb") do |f|
      f.write(file.read)
    end

    self.image_url = filename

    self.save
  end
end
