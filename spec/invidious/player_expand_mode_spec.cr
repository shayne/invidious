require "../spec_helper"

Spectator.describe "Player expand mode assets" do
  let(:player_js) { File.read("assets/js/player.js") }
  let(:player_css) { File.read("assets/css/player.css") }

  it "adds an expand control before fullscreen" do
    expand_index = player_js.index("'expandToggle'")
    fullscreen_index = player_js.index("'fullscreenToggle'")

    expect(expand_index.nil?).to be_false
    expect(fullscreen_index.nil?).to be_false
    expect(expand_index.not_nil! < fullscreen_index.not_nil!).to be_true
    expect(player_js.includes?("ExpandToggle")).to be_true
  end

  it "persists the page-level expanded player mode" do
    expect(player_js.includes?("watch_player_expanded")).to be_true
    expect(player_js.includes?("watch-player-expanded")).to be_true
    expect(player_js.includes?("helpers.storage.set")).to be_true
  end

  it "styles expanded watch players edge-to-edge without changing aspect ratio" do
    expect(player_css.includes?("body.watch-player-expanded #player-container")).to be_true
    expect(player_css.includes?("width: 100vw")).to be_true
    expect(player_css.includes?("aspect-ratio: var(--player-aspect-ratio")).to be_true
    expect(player_css.includes?("object-fit: contain")).to be_true
  end
end
