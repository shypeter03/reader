//
//  ReaderView.swift
//  Reader
//
//  一本书的唯一界面：正文。
//
//  路由口径（对齐图书 App）：书库点书 = 直接进这一页，中间不再插一层书籍详情；
//  章节列表收在正文上唤出的「目录」里；朗读控制在正文下方那条坞里；
//  单击按宽度分区——左右两条翻页，中间那块留给「点哪句从哪句朗读」。
//

import SwiftUI

struct ReaderView: View {

    let book: Book

    private let pipeline =
            ReaderContainer.shared.pipeline

    private let bookStore = BookStore.shared

    /// 当前这一章。可变，因为切章有两条路：用户在目录里点，以及播到章末自动推进。
    @State private var descriptor: ChapterDescriptor

    @State private var chapter: Chapter?

    /// 正文取不到的原因。之前只往控制台 print，界面永远停在「正在加载章节…」：
    /// 那种转圈既不是进度也不是结果，用户只能反复退出重进。
    @State private var loadError: String?

    /// 分页结果。只在「章 / 句数 / 页尺寸 / 字号行距」变化时重算。
    @State private var layout = PageLayout.placeholder

    /// 分页每换一版就 +1。它必须进纸面的内容口径（`pageContentKey`）：
    /// 首次进来 `layout` 还是 placeholder（一页、空的），`CurlPageTurner` 照着它
    /// 建好了第 0 面的缓存；随后真分页算出来，章/尺寸/字号一个都没变，
    /// 内容口径也就没变——缓存那一面永远不会重画。表现就是
    /// 「退出阅读器再点进来，第一页空白，翻一页才有字」。
    @State private var layoutEpoch = 0

    /// 卷页容器里现在摊着哪些纸：正文那一段 + 预取进来的相邻那一两章。
    /// 页码在两头之外都算得出来，所以它是「第几页」这件事的唯一口径。
    @State private var spine = TurnSpine()

    /// 现在手上这一版分页是按哪些输入量出来的（`layoutKey` 那一套）。
    /// 跨章时相邻那一章的分页是预取时算好的，这一位让 `rebuildLayout` 认出
    /// 「已经量过了」，不再在读者翻页的那一下重跑整章量高。
    @State private var layoutHeldFor = ""

    @State private var currentPage = 0

    /// 翻到章边界要接上相邻一章：这一位记下新章该落在哪一头，nil = 没排队。
    /// 手动翻页落在章首/章尾，跟着音频换章才落在正在播的那一句上。
    @State private var landingEdge: PageEdge?

    /// 读者自己翻过页之后，音频就不该再把页码**往回**拽——那表现是「怎么翻都翻不动」。
    /// 点某一句开始朗读时再接回来：那一下是人自己定的位置。
    ///
    /// 但它不是一刀切的黑白锁：判据是「手翻到的那一页在声音的哪一边」，
    /// 见 `noteManualTurn`。往前翻（声音还在后面）要留着跟随，否则
    /// 「播到下一页自动翻页」就永远不发生了。
    @State private var followAudio = true

    /// 下拉关闭：这一拖已经走了全程的多少（0 = 原位，1 = 已经按到封面卡上）。
    @State private var pullTravel: Double = 0

    /// 整页的高度，下拉关闭按屏高比例算行程。
    @State private var pageSize: CGSize = .zero

    @State private var lastPersistedSentence = -1

    /// 本布局对应哪一章：换章那一次要把页码对齐到正在播的那句。
    @State private var layoutChapterID: UUID?

    /// 换这个值才重新 `player.start(...)`。它和 `descriptor.id` 分成两个开关是必要的：
    /// 播到章末自动推进的那一章，正文和音频已由 PlayerManager 装配好交过来，
    /// 这里跟着 descriptor 重开一次等于把播放掐断重来。
    @State private var openToken = 0

    // MARK: - Chrome

    @State private var chromeVisible = false

    @State private var showOutline = false

    @State private var showTypography = false

    /// 唤出后自动收回的计时。
    @State private var chromeExpiry: Task<Void, Never>?

    /// 攒着还没起播的那一次点句朗读。第二下在窗口内到达就把它取消掉——
    /// 那一下是双击，只该唤按钮。
    @State private var pendingPlay: Task<Void, Never>?

    /// 上一次点击什么时候落的。双击、以及同一层对同一下点击的重复上报都按它判。
    @State private var lastTapAt = Date.distantPast

    /// 上一次左边缘那一划什么时候在动。边缘条上的点击和右滑挂在同一个视图上，
    /// 松手时两路都会报——不认这个，滑出去的那一下会被点击当成「翻一页」，
    /// 读者想关页面，结果纸先翻过去一张。
    @State private var lastSwipeAt = Date.distantPast

    /// 算作「第二下」的间隔。比系统的双击窗口短一点：宁可慢半拍起播，
    /// 也不要双击时把那一句读出来。
    private static let tapWindow: TimeInterval = 0.25

    /// 同一下点击的两路上报（句子 run + 整页）之间最大的间隔。不并成一下，
    /// 点一句正文就会被当成双击。
    private static let tapEcho: TimeInterval = 0.06

    /// 左右两条翻页带各占页宽的这一成，中间剩下的留给「点哪句从哪句朗读」。
    /// 和拖动的临界位移取同一个数：两条路都往那个方向走，占地就该一样。
    private static let turnZoneRatio: Double = 0.22

    /// 上一次点击落在翻页带里是什么时候。同一下点击也会被报成「点到了某一句」，
    /// 靠它把那一次朗读作废掉——分区的意思就是这一下只翻页。
    /// 它同时也是边缘条那一下的去重记号：两层都可能报同一次点击，只认第一下。
    @State private var lastZoneTurnAt = Date.distantPast

    /// 边缘手势条的宽度。它就是翻页带最靠屏幕边的那一截：点击照样翻页，
    /// 只是左边缘那一条额外认右滑返回。再宽就要吃掉版心里的落点了。
    private static let edgeStripWidth: CGFloat = 30

    /// 顶部下滑条的高度。它从屏幕最上沿开始（下拉关闭要从边上起手），
    /// 但状态栏那一段只给手势、不给点击：那里没有按钮，也不该有。
    private static let topEdgeHeight: CGFloat = 44

    /// 返回手势走过多远才算数。再小就会和「点一下唤出按钮」抢。
    private static let pullThreshold: CGFloat = 12

    /// 下拉关闭要走完屏高的这一比例才关。
    private static let dismissRatio: CGFloat = 0.4

    /// 按钮停留多久自己收回去。比一句朗读的时间长，省得正听着的时候条忽然没了。
    private static let chromeAutoHide: TimeInterval = 4

    /// 手动跨章时要落在新章的那一头。
    private enum PageEdge {

        case head

        case tail
    }

    @AppStorage("fontSize")
    private var fontScale: Double = 1.0

    @AppStorage("lineSpacingScale")
    private var lineScale: Double = 1.0

    /// 键必须与 `ReaderTheme.storageKey` 一致（@AppStorage 只接受字面量）。
    @AppStorage("readerTheme")
    private var themeRaw: String = ReaderTheme.paper.rawValue

    @AppStorage("autoScroll")
    private var autoFollow = true

    /// 语音播报总开关，和底部条上那颗按钮、设置页那个 Toggle 是同一个键。
    /// 关掉之后点正文只是翻页不朗读，所以那一行的高亮也跟着撤掉——
    /// 没有声音在跟它，留着绿色那行就是骗人。
    @AppStorage(
        PlayerManager.speechEnabledKey
    )
    private var speechEnabled = true

    @ObservedObject
    private var player = PlayerManager.shared

    /// 系统现在哪一档。只拿来定 UIKit 那层的 traits（见 `paperAppearance`）：
    /// 纸色本身一律由 `ReaderTheme` 的动态色现算，不在这里判断深浅——
    /// 那样每个用到 theme 的地方都得自己接一遍环境值，漏一处就是「切深色了正文还是白底」。
    @Environment(\.colorScheme)
    private var systemScheme: ColorScheme

    /// 下拉关闭要改的就是它那一层的 `presentation`：整页缩回封面卡是同一个动作，
    /// 不该在阅读页里再画一份缩放。
    @ObservedObject
    private var launcher = ReaderLauncher.shared

    /// 收回书库。这一页现在是根视图自己叠的一层，不是系统 presented 的，
    /// `dismiss()` 在这里是空操作，关闭只能由叠它的那一层给动作。
    let onClose: () -> Void

    init(
        book: Book,
        chapterDescriptor: ChapterDescriptor,
        onClose: @escaping () -> Void
    ) {
        self.book = book
        self.onClose = onClose
        _descriptor = State(
            initialValue: chapterDescriptor
        )
    }

    private var theme: ReaderTheme {
        ReaderTheme(rawValue: themeRaw) ?? .paper
    }

    /// 卷页那层（UIKit）该按哪套 traits 上色。和屏幕上那块底色同源：底色走
    /// `theme.background`，它按 pager 的 traits 现算；这里把同一个结论直接递给
    /// UIKit，两边就不可能在「切深浅的那一帧」错开——纸跟着底色走。
    private var paperAppearance: UIUserInterfaceStyle {
        theme.userInterfaceStyle(
            matching: systemScheme == .dark ? .dark : .light
        )
    }

    /// 条是否处于显示状态。Aa 面板开着时不能把整条 chrome 收走，
    /// 否则用户字号调到一半，面板跟着没了。
    private var chromeShown: Bool {
        chromeVisible || showTypography
    }

    var body: some View {

        ZStack {

            theme.background
                .ignoresSafeArea()

            Group {

                if let chapter {

                    readerContent(
                        chapter
                    )

                } else if let loadError {

                    // 转圈不等于进度：正文取不到时必须把原因摊开，否则用户只能
                    // 一直盯着「正在加载章节…」（部署丢内容时就是这个现象）。
                    loadFailure(loadError)

                } else {

                    ProgressView(
                        "正在加载章节…"
                    )
                }
            }

            // 章名不在这里画了：它得是纸的一部分，卷页时跟着纸一起走，
            // 钉在屏幕上就成了「只有正文在翻」（见 `ReaderPageView`）。

            // 顺序有讲究：chrome 必须在 edgeZones 之上。两条边条是通高的，
            // 正好压住顶栏左端的「返回」和底条两端的「倍速」——放在上面
            // 就会把按钮的点击吃掉，表现是「按钮画出来了但点了没反应」。
            edgeZones

            chrome
        }
        .task(id: openToken) {

            await openCurrentChapter()
        }
        .task(id: descriptor.id) {

            await watchUpdates()
        }
        .onChange(of: player.currentChapter?.id) { _, newID in

            // PlayerManager 自动切换到下一章时，正文和目录都要跟过去
            guard newID != nil,
                  let played = player.currentChapter,
                  played.id != chapter?.id
            else {
                return
            }

            // 声音自己跨了章。那一章的纸如果已经摊在页序里（预取过），正文就换到那一段：
            // 两头下标都不动，容器看到的还是「往前走了一面」，卷页照演。
            // 不在页序里才留着旧纸转圈——那是老路，那一下没有动画。
            if let at = spine.sheet(ofChapter: played.id) {
                applyMain(at, page: at.layout.page(containing: player.currentSentenceIndex))
            }

            self.chapter = played

            lastPersistedSentence = -1

            if book.chapters.indices.contains(player.currentChapterIndex) {
                self.descriptor = book.chapters[player.currentChapterIndex]
            }

            persistProgress(force: true)
        }
        .onGeometryChange(
            for: CGSize.self,
            of: { $0.size },
            action: { pageSize = $0 }
        )
        .onDisappear {

            // 关章 / 退到书单：把最后这一句落盘，下次进来才接着读
            persistProgress(force: true)
            chromeExpiry?.cancel()
            pendingPlay?.cancel()
            pendingPlay = nil
        }
        .sheet(
            isPresented: $showOutline
        ) {

            ChapterOutlineView(
                book: book,
                currentChapterID: descriptor.id
            ) { picked in
                goTo(picked)
            }
        }
    }

    // MARK: - Open / watch

    /// 打开当前这一章：装配（书单、下一章回调、排产锚点）都在 `player.start` 里。
    ///
    /// openChapter 立刻返回正文；AI/TTS 的结果走 `watchUpdates` 那条流补回来，
    /// 绝不参与「这一章能不能打开」的判断。
    private func openCurrentChapter() async {

        // 播放器正播着这本书的这一章：现场接着用，一次都不重新 start。
        // 重新走一遍会先 stop() 把声音掐了，再把位置倒回书单里那份进度——
        // 那份进度是退出阅读页那一刻写的，声音后来又往前跑了几个字。
        if let playing = player.currentChapter,
           player.currentBook?.id == book.id,
           playing.id == descriptor.id {

            self.chapter = playing
            lastPersistedSentence = player.currentSentenceIndex

            return
        }

        let currentIndex =
            book.chapters.firstIndex {
                $0.id == descriptor.id
            } ?? 0

        loadError = nil

        do {

            let initial = try await player.start(
                book: book,
                chapter: descriptor,
                // 只有「接着上次那章」才恢复句序；另开一章从章首读起。
                restoreTo: currentIndex == book.lastReadChapter
                    ? book.lastReadSentence : nil,
                pipeline: pipeline
            )

            self.chapter = initial

            applyLayout(initial)

            lastPersistedSentence = player.currentSentenceIndex

            // 打开即落一次位置：只读三句就退出的话，进度也该跟到这一章
            persistProgress(force: true)

        } catch {

            // 分开报两种情况：正文文件没了（⌘R 部署后就是这条，见书单记的绝对路径）
            // 和读得出文件但解不开。前者重试一万次也没用，只能重新导入。
            let gone = !FileManager.default.fileExists(atPath: descriptor.fileURL.path)
            loadError = gone
                ? "这一章的正文文件已不在本机：\(descriptor.href)\n重新导入这本书即可恢复。"
                : "取不到这一章的正文：\(error.localizedDescription)"
            print("章节加载失败:", error, "path:", descriptor.fileURL.path)
        }
    }

    /// 订阅这一章新生成的标注与音频。换章（含自动推进）就换订阅，
    /// 否则新章的合成结果永远进不来，播放会停在等不到的那一句上。
    private func watchUpdates() async {

        do {
            for try await updated in await pipeline.chapterUpdates(descriptor.id) {
                self.chapter = updated
                player.updateSentences(updated.sentences)
            }
        } catch {
            print("⚠️ [阅读页] 章节更新流中断：\(error)")
        }
    }

    /// 目录里点了一章：换订阅目标 + 重新打开。
    ///
    /// 只有这一条路和「声音推进到没预取到的那一章」是整份页序重数：跳过去的那一章
    /// 和眼前这一段没有任何接续关系，纸要从头摊。跨章不是（见 `TurnSpine`）。
    private func goTo(_ target: ChapterDescriptor) {

        guard target.id != descriptor.id else { return }

        // 攒着还没起播的那一次点句朗读是上一章的句子号，换章后不能再放行。
        pendingPlay?.cancel()
        pendingPlay = nil

        spine.reset()

        descriptor = target
        chapter = nil
        loadError = nil
        openToken += 1
    }

    /// 翻到章边界：把相邻那一章当成下一页接上。从哪一侧来就落在哪一头——
    /// 往前翻落在新章第一页，往回翻落在上一章最后一页，正文读起来是一整本，
    /// 不是一章一章被墙挡住。
    ///
    /// 这是预取没赶上时的老路：现取正文、现算分页，纸只能先换成转圈再落回去，
    /// 那一下没有卷页。正常情况下读者碰不到（`prefetchNeighbors` 早一步把纸摊好了）。
    private func turnChapter(
        forward: Bool
    ) {

        guard let target = neighborDescriptor(forward: forward) else { return }

        landingEdge = forward ? .head : .tail

        // 往前翻落在新章第一页，而 `goTo` 会把声音也带回这一章开头（`player.start`
        // 里就是句序 0）：人和声都在头上，章内的跟随规矩照用。
        // 往后翻落在最后一页，声音却从头念起——那一页在声音后面，跟上去等于把页
        // 一路往前拽，所以这一向不跟，直到点某一句重新起播。
        followAudio = forward

        goTo(target)
    }

    /// 相邻那一章是哪一章。头/尾两章给 nil（这本书到边了）。
    func neighborDescriptor(
        forward: Bool
    ) -> ChapterDescriptor? {

        let at = book.chapters.firstIndex {
            $0.id == descriptor.id
        } ?? descriptor.index

        let target = forward ? at + 1 : at - 1

        return book.chapters.indices.contains(target) ? book.chapters[target] : nil
    }

    // MARK: - Reading progress

    /// 阅读位置落盘（章下标 + 章内句序）。切一句写一次会把整份书单重新编码，
    /// 所以按句序节流：攒够 8 句才写，换章 / 关章时强制写一次。
    private func persistProgress(force: Bool = false) {

        let chapterIndex = player.currentChapterIndex

        let sentenceIndex = player.currentSentenceIndex

        guard force
              || abs(sentenceIndex - lastPersistedSentence) >= 8
        else {
            return
        }

        lastPersistedSentence = sentenceIndex

        let bookID = book.id

        Task {
            await bookStore.setProgress(
                bookID: bookID,
                chapterIndex: chapterIndex,
                sentenceIndex: sentenceIndex
            )
        }
    }
}

// MARK: - Content

private extension ReaderView {

    func readerContent(
        _ chapter: Chapter
    ) -> some View {

        GeometryReader { geometry in

            pageReader(
                chapter,
                size: geometry.size
            )
            .contentShape(Rectangle())
            // 单击按宽度分区：左右两条各 `turnZoneRatio` 翻页，中间照旧
            // （点句朗读 + 双击唤按钮）。
            //
            // 用「带位置的点击」而不是在两侧盖两条视图：那两条会压在文字上，
            // 落在两侧的句子从此读不到落点；而分区要的本来就是「这一下落在哪」，
            // 不是「这一下盖住了谁」。
            // 没有字的那片地方也算一次点击：只用来接双击的第二下（见 `handleTap`）。
            .onTapGesture(
                count: 1,
                coordinateSpace: .local
            ) { location in
                handleZoneTap(
                    x: location.x,
                    width: geometry.size.width
                )
            }
            // 这一句才是「整页都在翻」的关键：`ignoresSafeArea` 把里面那个 UIKit 翻页
            // 容器的 frame 撑到整屏（探针量过：顶=0、底=屏高；不加就停在 62…446），
            // 卷页是照着它的 bounds 画的，撑不满纸就还是只有中间那一块。
            .ignoresSafeArea()
        }
        // 页码跟着安全区，不跟着纸：它的落点是照安全区底边量的。
        .overlay(
            alignment: .bottomTrailing
        ) {
            pageIndicator
        }
    }

    /// 正文取不到时的界面：说清是哪一章、为什么，给出能做的两件事。
    func loadFailure(
        _ message: String
    ) -> some View {

        VStack(spacing: 14) {

            Image(systemName: "doc.warn")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text(
                "打不开「\(descriptor.title)」"
            )
            .font(.headline)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                loadError = nil
                openToken += 1
            } label: {
                Text("重新加载")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func pageReader(
        _ chapter: Chapter,
        size: CGSize
    ) -> some View {

        // 页眉那一段是从纸里让出去的，不是盖在正文上的：正文量的高度和
        // 渲染用同一块地方，否则页尾会溢出去（分页算 40 行、实际只放得下 37 行）。
        // 减法只写在 `ReaderPageBox` 里：这里的 `size` 是整屏那份（外层 ignoresSafeArea），
        // 以前各写一遍，量到 763pt 而纸上只有 670pt，每页最后两行掉在纸外面。
        let area = ReaderPageBox.bodyArea(size)

        let main = mainSheet(chapter)

        return CurlPageTurner(
            // 页序不一定从第 0 面开始：上一章的纸贴在正文前面时，正文第一面的下标是负的。
            startIndex: spine.startIndex(main: main),
            pageCount: spine.pageCount(main: main),
            // 换代才作废缓存：跨章不算换代（相邻那两段本来就在页序里，每个下标还是同一面纸）。
            revision: "v\(spine.generation)",
            // 纸上这一面的全部输入。翻页只是页码动，不该让缓存里那几页重排一遍。
            contentRevision: pageContentKey(chapter, area),
            // 卷页的纸色跟着主题走：深色模式下翻起来那张纸也得是深色的。
            paper: theme.uiBackground,
            // 光给动态色不够，还得把 UIKit 那层的 traits 钉在同一档：
            // 缓存里的纸大多不在视图树上，系统切深浅时它们收不到更新。
            appearance: paperAppearance,
            page: pageBinding,
            onUserTurn: { landed in
                noteManualTurn(to: landed)
            }
        ) { pageIndex in

            pageView(at: pageIndex, main: main)
        }
        .task(id: layoutKey(chapter, area)) {

            rebuildLayout(chapter, size: area)
        }
        // 相邻那一章的纸提前摊进页序。key 和分页同一个：换章、改字号行距、页宽变了
        // 都要重新预取——旧的那两段起点已经不作数了。
        .task(id: "prefetch|\(layoutKey(chapter, area))") {

            await prefetchNeighbors(area: area)
        }
        .onChange(of: player.currentSentenceIndex) { _, newIndex in

            onSentenceChanged(newIndex)
        }
    }

    /// 正文那一段现在长什么样。视图自己管着 `chapter` / `layout`，页序只记着它的起点。
    func mainSheet(_ chapter: Chapter) -> TurnSpine.Sheet {

        TurnSpine.Sheet(
            descriptor: descriptor,
            chapter: chapter,
            layout: layout,
            base: spine.mainBase,
            key: layoutHeldFor
        )
    }

    /// 第 index 面纸。可能是正文那一面，也可能是预取进来的相邻那一面。
    ///
    /// 相邻那一面不给跟读的绿字，也不认点击：那一句不在播放器手上，点它就是拿
    /// 另一章的句子号去起播——念出来的和点的不是同一句。
    func pageView(
        at index: Int,
        main: TurnSpine.Sheet
    ) -> ReaderPageView {

        let found = spine.sheet(at: index, main: main)

        let sheet = found?.sheet ?? main
        let local = found?.local ?? 0
        let isMain = found.map { $0.sheet.chapter.id == main.chapter.id } ?? true

        /// 这一页摊几栏、每栏从哪儿起、每栏的行距挪多少。越界时它退回单栏 + 0，
        /// 和下面 `slices` 那一句的「拿不到就交空页」是同一个兜底口径。
        let spread = sheet.layout.columns(onPage: local)

        return ReaderPageView(
            sentences: sheet.chapter.sentences,
            slices: sheet.layout.pages.indices.contains(local)
                ? sheet.layout.pages[local]
                : [],
            bodySize: sheet.layout.bodySize,
            lineScale: lineScale,
            columnCuts: spread.cuts,
            columnStretch: spread.stretch,
            theme: theme,
            chapterTitle: sheet.chapter.title,
            activePosition: isMain && speechEnabled
                ? player.currentSentenceIndex
                : nil,
            tap: { position in
                // [Tap] 取证（#162）：点到了预取进来的相邻那一面——那一句不在播放器手上，
                // 按口径就该丢掉，但得看得见是这一条丢的，别记到「派发」头上。
                guard isMain else {
                    print("[Tap] 丢：落在相邻那一面的纸上 pos=\(position)")
                    return
                }
                handleTap(position)
            },
            runningHead: sheet.descriptor.backLabel,
            headOpacity: chromeShown ? 0 : 1
        )
    }

    /// 把相邻那一章的纸先摊进页序：读正文（调度器的 actor 里）+ 分页（不等主线程）+ 贴两头。
    ///
    /// 为什么要提前：到了边界才现取现算，那一下就没有「下一面」可卷——纸只能先闪白
    /// 换成下一章（这就是「跨章没有动画」），而那一次点击还要等一回磁盘读加整章量高。
    func prefetchNeighbors(
        area: CGSize
    ) async {

        // 下一章优先：往下读是常态，往前翻回去的那一段正文本来就还在手上。
        await prepareNeighbor(forward: true, area: area)
        await prepareNeighbor(forward: false, area: area)
    }

    func prepareNeighbor(
        forward: Bool,
        area: CGSize
    ) async {

        guard let target = neighborDescriptor(forward: forward),
              let shown = chapter
        else {
            return
        }

        let loaded: Chapter

        do {
            loaded = try await pipeline.readChapter(target, bookID: book.id)
        } catch {
            // 预取取不到不影响读：翻到那一头还是老路（现取现算），只是那一下没卷页。
            print("[Turn] 预取\(forward ? "下" : "上")一章《\(target.title)》失败：\(error.localizedDescription)")
            return
        }

        // 整章量高挪出主线程。`paginate` 是同步纯函数，几百句要量几十毫秒——
        // 压在读者翻页的那一下手感上，值不得。
        let sentences = loaded.sentences
        let title = loaded.title
        let scale = fontScale
        let spacing = lineScale

        let laid = await Task.detached(priority: .utility) {
            PageLayout.paginate(
                sentences,
                in: area,
                scale: scale,
                lineScale: spacing,
                chapterTitle: title
            )
        }.value

        let sheet = TurnSpine.Sheet(
            descriptor: target,
            chapter: loaded,
            layout: laid,
            base: 0,
            key: layoutKey(loaded, area)
        )

        // 等回来的时候这一页可能已经换章了（读者翻走了、Aa 面板改了字号），
        // 那份纸的起点和量法都不作数了，丢掉让下一条 task 重取。
        guard !Task.isCancelled, shown.id == chapter?.id else { return }

        if forward {
            spine.attachAfter(sheet, main: mainSheet(shown))
        } else {
            spine.attachBefore(sheet, main: mainSheet(shown))
        }
    }

    /// 点正文。`position` = 点到的那一句，nil = 点到没有字的地方。
    ///
    /// 起播和唤按钮都只从这一个口子走，所以「双击顺带把那句读了一遍」不可能再发生：
    /// 第一下先攒 `tapWindow` 再起播，期间再来一下就是双击——把攒着的那次朗读作废，
    /// 只唤按钮。代价是单击起播慢 0.25s，换来双击就是双击、单击就是单击。
    ///
    /// [Tap] 取证（#162）：同一下点击有两路上报（run 的 link 和外面的分区点击），
    /// 落到哪个分支、两路隔了多少毫秒，只能从日志里读——「点了没反应」在屏幕上
    /// 长得一模一样，分支不打分就分不出是派发丢了还是仲裁误判。
    func handleTap(
        _ position: Int?
    ) {

        let now = Date()

        let sinceLast = now.timeIntervalSince(lastTapAt)

        lastTapAt = now

        let gap = Int(sinceLast * 1000)

        print("[Tap] 分支入口 pos=\(String(describing: position)) 距上次 \(gap)ms 有在飞的起播=\(pendingPlay != nil)")

        if now.timeIntervalSince(lastZoneTurnAt) < Self.tapEcho {
            // 这一下已经被翻页带认走了：同一下点击的两路上报，以翻页为准。
            print("[Tap] 分支=已被翻页带走")
            return
        }

        if sinceLast < Self.tapEcho {
            // 同一下点击被两层各报了一次：以拿到句子的那次为准，不再另起一次。
            print("[Tap] 分支=回声 \(gap)ms")
            if let position, pendingPlay == nil {
                schedulePlay(position)
            }
            return
        }

        if pendingPlay != nil || sinceLast < Self.tapWindow {
            print("[Tap] 分支=当作双击（取消在飞的起播）\(gap)ms")
            pendingPlay?.cancel()
            pendingPlay = nil
            toggleChrome()
            return
        }

        if let position {
            schedulePlay(position)
        } else {
            print("[Tap] 分支=空处，什么都不做")
        }
    }

    func schedulePlay(
        _ position: Int
    ) {

        // 播报关着：点句只是点句，不排那 0.25s 的起播。
        guard speechEnabled else {
            print("[Tap] 不起播：语音播报关着 pos=\(position)")
            return
        }

        print("[Tap] 排起播 pos=\(position)（\(Int(Self.tapWindow * 1000))ms 后才真开口）")

        pendingPlay = Task { @MainActor in

            try? await Task.sleep(
                nanoseconds: UInt64(Self.tapWindow * 1_000_000_000)
            )

            guard !Task.isCancelled else { return }

            pendingPlay = nil

            // 这一句是人自己点的，页该重新跟着声音走了。
            followAudio = true

            print("[Tap] 起播 pos=\(position)")

            player.playSentence(at: position)
        }
    }

    /// 单击落在哪一区：左右两条翻页带各自翻页，中间还按老规矩走
    /// （点句朗读、双击唤按钮）。
    ///
    /// 按页宽的比例算而不是定死点数——小屏大屏都要是「拇指一伸就够到的边」。
    /// 最外面那 30pt 由边缘条盖着（`edgeStripWidth`），那一路也报成翻页，
    /// 所以落点分到哪儿都是翻一页；两层各报一次同一下点击由 `lastZoneTurnAt` 去重。
    /// 唤按钮不再从边缘来，改走正文中部双击（`handleTap`）。
    func handleZoneTap(
        x: CGFloat,
        width: CGFloat
    ) {

        guard width > 0 else { return }

        let band = width * Self.turnZoneRatio

        // [Tap] 取证（#162）：分区这一路拿到的是哪条带、落点离边多远。
        print("[Tap] 路=zone x=\(String(format: "%.0f", x)) 带宽=\(String(format: "%.0f", band)) 屏宽=\(String(format: "%.0f", width))")

        if x < band {
            turnPage(forward: false)
        } else if x > width - band {
            turnPage(forward: true)
        } else {
            handleTap(nil)
        }
    }

    /// 点两侧翻一页；翻到这一章的头/尾就接相邻那一章，和拖到底走同一条路。
    func turnPage(
        forward: Bool
    ) {

        let now = Date()

        // 边缘条那 30pt 在正文那层之上，同一点击两路都会报：只认第一下，
        // 不然点一下屏幕边就是翻两页。
        guard now.timeIntervalSince(lastZoneTurnAt) > Self.tapEcho else {
            return
        }

        lastZoneTurnAt = now

        // 落在两侧的字上时，那一句话的朗读已经由 run 的 link 攒下了（两路上报的
        // 先后不一定）。同一下点击不能既翻页又在 0.25s 后开口读一句。
        if pendingPlay != nil,
           now.timeIntervalSince(lastTapAt) < Self.tapEcho {
            pendingPlay?.cancel()
            pendingPlay = nil
        }

        let target = forward ? clampedPage + 1 : clampedPage - 1

        if layout.pages.indices.contains(target) {

            // 翻页动画归 `CurlPageTurner`：这里只交页码（见 `onSentenceChanged`）。
            currentPage = target

            noteManualTurn(to: spine.mainBase + target)

            return
        }

        // 章边界。相邻那一章的纸已经摊在页序里（预取赶上了）的话，这一下和章内翻页
        // 在容器眼里是同一件事：往前走一面，卷页照演。
        let landing = spine.neighbor(forward: forward).map { sheet in
            forward ? sheet.base : sheet.base + sheet.layout.pageCount - 1
        }

        if let landing, cross(forward: forward, landing: landing) {
            noteManualTurn(to: landing)
            return
        }

        turnChapter(forward: forward)
    }

    /// 读者自己翻到某一页（点两侧、拖纸都走这里，交的是整份页序里的第几面）。
    /// 音频还能不能把页码带走，看这一面落在声音的哪一边：
    ///
    /// - 落在声音那一面**或它之后**：跟着。往前翻是想早点看到下文，不是不要跟读了，
    ///   纸停在读者那一面等声音追上来（`onSentenceChanged` 只往跨过去的方向走，
    ///   不会把人往后拽），声音跨过读者这一面的边界就自动接上。
    /// - 落在声音**前面**（往后翻去重读）：解开跟随。那一面声音已经念过去了，
    ///   再跟就是把页从读者要看的地上往回拽。点某一句重新起播才接回来。
    ///
    /// 两边都在页序里比，所以跨章那一下不需要另开一条规矩：往前翻进下一章，声音还在
    /// 上一章的纸上，读者在前、声音在后 → 跟着；往后翻回上一章的最后一页，声音从
    /// 下一章开头念起，读者在后 → 不跟。声音那一章压根不在页序里（中间那些纸还没摊开）
    /// 才比不出高低，跟随留着，等声音进了这一段再按上面的规矩走。
    func noteManualTurn(
        to landed: Int
    ) {

        guard let chapter,
              let playing = player.currentChapter,
              let audio = spine.spacePage(
                  ofSentence: player.currentSentenceIndex,
                  in: playing,
                  main: mainSheet(chapter)
              )
        else {
            followAudio = true
            return
        }

        followAudio = landed >= audio
    }

    /// 容器那一头的下标是整份页序的，这里这一头还是「本章第几页」：胶水在这根 Binding 上。
    ///
    /// 它同时是跨章的入口：读者拖出来那一下落在相邻那一段里时，`CurlPageTurner` 落定以后
    /// 先写这根、再报 `onUserTurn`——换章就在这儿办，办完页码自然对得上（`onUserTurn`
    /// 拿到的那个下标此时已经是正文那一章的了）。
    var pageBinding: Binding<Int> {

        Binding(
            get: {
                spine.mainBase + clampedPage
            },
            set: { newValue in
                // 落点出了正文那一段 = 读者把纸拖进了相邻那一章。
                if newValue != spine.mainBase + clampedPage,
                   crossIfNeeded(toSpace: newValue) {
                    return
                }

                currentPage = min(
                    max(newValue - spine.mainBase, 0),
                    max(layout.pageCount - 1, 0)
                )
            }
        )
    }

    /// 眼前这一页收在本章的页数里。
    var clampedPage: Int {
        min(max(currentPage, 0), max(layout.pageCount - 1, 0))
    }

    /// 落点不在正文那一段里就换章。方向一看下标就知道：比正文的头还前，或者比尾还后。
    func crossIfNeeded(
        toSpace index: Int
    ) -> Bool {

        if index >= spine.mainBase + layout.pageCount {
            return cross(forward: true, landing: index)
        }

        if index < spine.mainBase {
            return cross(forward: false, landing: index)
        }

        return false
    }

    /// 把正文换成相邻那一段，纸落在 `landing` 这一面。返回 false = 那一段还没摊开。
    ///
    /// 两段的下标都不动（`TurnSpine` 只允许贴两头），所以卷页容器那边等于什么都没发生：
    /// 它只是往前/往后走了一面纸，动画也就是最普通的那一段卷页。
    func cross(
        forward: Bool,
        landing: Int
    ) -> Bool {

        guard let chapter,
              let next = spine.neighbor(forward: forward),
              next.layout.pages.indices.contains(landing - next.base)
        else {
            return false
        }

        let main = mainSheet(chapter)

        if forward {
            spine.commitForward(from: main)
        } else {
            spine.commitBackward(from: main)
        }

        applyMain(next, page: landing - next.base)

        return true
    }

    /// 换段落账。
    ///
    /// 正文已经在手上（就是页序里那一段），所以这里不转圈、不重算分页：
    /// `openToken` 那一跳只要把声音和排产挪到这一章来。
    func applyMain(
        _ sheet: TurnSpine.Sheet,
        page: Int
    ) {

        // 攒着还没起播的那一次点句朗读是上一章的句子号，换章后不能再放行。
        pendingPlay?.cancel()
        pendingPlay = nil

        descriptor = sheet.descriptor
        chapter = sheet.chapter
        layout = sheet.layout
        layoutHeldFor = sheet.key
        layoutChapterID = sheet.chapter.id
        currentPage = min(
            max(page, 0),
            max(sheet.layout.pageCount - 1, 0)
        )
        openToken += 1
    }

    var pageIndicator: some View {

        // 落点不给在这儿调：这一行的高就是 `ReaderPageBox.textBottom` 扣出来的那一段，
        // 两边都取 `PageNumberBar`，改了行高分页和纸面跟着一起动。
        PageNumberBar(
            text: "\(min(currentPage + 1, layout.pageCount)) / \(layout.pageCount)",
            color: theme.text.opacity(0.35)
        )
    }

    /// 分页输入。角色名**不在**里面：纸上不显示说话人，名字只给语音用，
    /// 所以 LLM 后补的名字不会改动一行高度，也就不该触发重排。
    func layoutKey(
        _ chapter: Chapter,
        _ size: CGSize
    ) -> String {

        """
        \(chapter.id.uuidString)|\(chapter.sentences.count)\
        |\(pageMetrics(size))
        """
    }

    /// 一次分页的输入里和「这一章有什么字」无关的那半：版心 + 字号 + 行距。
    /// 抽出来只为了 `layoutKey` 是它唯一的 superset，两处共用同一份口径。
    func pageMetrics(
        _ size: CGSize
    ) -> String {
        "\(Int(size.width))x\(Int(size.height))|\(fontScale)|\(lineScale)"
    }

    /// 纸面上这一面的全部输入——也就是 `ReaderPageView` 那几个参数。
    ///
    /// 少了其中任何一项，`CurlPageTurner` 就会在该重画的时候不重画：
    /// 漏了 `activePosition`，跟读的那一行绿字停在原地不动；漏了 chrome 那一项，
    /// 页眉该让位的时候没让。反过来，只写页码不动它就不重排，点两侧翻页才不卡。
    func pageContentKey(
        _ chapter: Chapter,
        _ size: CGSize
    ) -> String {

        let active = speechEnabled ? player.currentSentenceIndex : -1

        return """
        \(layoutKey(chapter, size))|\(layoutEpoch)|\(chapter.title)|\(descriptor.backLabel)\
        |\(themeRaw)|\(active)|\(chromeShown ? 0 : 1)
        """
    }

    func rebuildLayout(
        _ chapter: Chapter,
        size: CGSize
    ) {

        let key = layoutKey(chapter, size)

        // 手上这一版分页就是按这些量出来的：不用再跑一遍整章量高。
        // 跨章交过来的那一份就是这种情况——预取时算好了，读者落上去直接用。
        guard key != layoutHeldFor else { return }

        let next = PageLayout.paginate(
            chapter.sentences,
            in: size,
            scale: fontScale,
            lineScale: lineScale,
            chapterTitle: chapter.title
        )

        let isNewChapter = layoutChapterID != chapter.id

        // 只在真变了的时候升一位：每次重排都升，跟读时那些「章没变、只是又算了一遍」
        // 的更新会把整窗口缓存页重画一遍，白卡。
        if layout != next {
            layout = next
            layoutEpoch += 1

            // 正文这一面重排了：两头那两段的起点是照旧的页数算的，留着要么和正文叠上、
            // 要么中间空出一段。丢掉，预取那条 task 会按新页数重贴。
            spine.detachNeighbors()
        }

        if isNewChapter {
            layoutChapterID = chapter.id

            // 正文换成一个不在页序里的章（目录跳章、声音推进到没预取到的那一章）：
            // 同一个下标从此是另一面纸，整份页序重数。
            spine.reset()
        }

        layoutHeldFor = key

        // 换章：手动翻过来的那一下落在章首/章尾，其余情况跟到正在播的那句
        // （打开时就是上次读到的那句）。
        if let edge = landingEdge {
            landingEdge = nil
            currentPage = edge == .head ? 0 : max(next.pageCount - 1, 0)
        } else if isNewChapter {
            currentPage = next.page(containing: player.currentSentenceIndex)
        } else {
            currentPage = min(currentPage, next.pageCount - 1)
        }
    }

    /// 正文刚换了一章、而这一章的纸还没重排（`openCurrentChapter` 交过来的那一份）。
    ///
    /// 不能只改 `chapter`：`layoutKey` 里没有音频状态，`rebuildLayout` 那条
    /// `.task(id:)` 不会因此重跑。于是新章那份纸（`layout` 还是上一章的、可能是空的）
    /// 一直不改写，容器只在 `contentRevision` 变化时才重画缓存——表现是
    /// 「点了没有返回，等下一次重排才跳到那一页」。这里当场把它擦掉，并且刻意让
    /// 纸面口径和上一次不同，那一次重排一定跑。
    ///
    /// `layoutChapterID` 留给 `rebuildLayout` 认「这是不是一章新的纸」：它一擦，
    /// 「落到正在播的那一句」那条落点规矩就没了。
    func applyLayout(
        _ chapter: Chapter
    ) {

        // 这一章的纸已经在手上了（跨章时从页序里交过来的那一份）：别把它擦成空的，
        // 更别再在主线程重量一遍。
        guard layoutChapterID != chapter.id else { return }

        layoutHeldFor = ""
        layout = .placeholder
        layoutEpoch += 1
        currentPage = 0
    }

    func onSentenceChanged(
        _ newIndex: Int
    ) {

        persistProgress()

        Task {
            await player.reportPosition(newIndex)
        }

        // 「自动续页」跟的是声音。播报关着的时候 `currentSentenceIndex` 不会动，
        // 但它停在退出播放那一刻那一句上：不认这一条，页会一路追着那个旧位置跑，
        // 表现就是翻页翻到章尾卡住、声音早没了。
        guard autoFollow,
              followAudio,
              speechEnabled,
              player.currentSentenceIndex == newIndex,
              player.currentChapter?.id == chapter?.id
        else {
            return
        }

        let target = layout.page(containing: newIndex)

        // 只朝声音跨过去的方向走，一格也不往回拽：读者往前翻过一页时声音还在后面，
        // 把页拉回去就是「怎么翻都翻不动」。声音追上来的那一格 `target == shown`，
        // 本来就不必看；再往前一格，跟随自然接上（见 `noteManualTurn`）。
        guard target > clampedPage else {
            return
        }

        // 翻页动画归 `CurlPageTurner`：这里只把页码交出去，别处再包一层
        // withAnimation 会和它内部的进度动画撞上，表现是纸翻到一半跳页。
        currentPage = target
    }
}

// MARK: - Chrome

private extension ReaderView {

    /// 上下两条按钮。正文一页到底，要用的时候才出现，几秒后自己收回——
    /// 常驻的工具条会把正文挤到半屏，翻页翻两句就到底。
    @ViewBuilder
    var chrome: some View {

        VStack(spacing: 0) {

            ReaderTopBar(
                onClose: onClose,
                onOutline: { showOutline = true },
                onTypography: {
                    showTypography.toggle()
                    scheduleChromeExpiry()
                }
            )
            .opacity(chromeShown ? 1 : 0)
            .offset(y: chromeShown ? 0 : -ReaderTopBar.totalHeight)

            Spacer()

            if showTypography {
                TypographyPanel()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            VoiceToolBar(
                player: player,
                sentenceCount: chapter?.sentences.count ?? 0,
                analysisStatus: chapter?.analysisStatus ?? .pending,
                ttsStatus: chapter?.ttsStatus ?? .pending,
                onRetry: {
                    Task {
                        await pipeline.retryChapter(
                            bookID: book.id,
                            chapterID: descriptor.id
                        )
                    }
                }
            )
            .opacity(chromeShown ? 1 : 0)
            .offset(y: chromeShown ? 0 : VoiceToolBar.totalHeight)
        }
        .animation(
            .easeOut(duration: 0.22),
            value: chromeShown
        )
        .allowsHitTesting(chromeShown)
    }

    /// 左边缘右滑 + 顶部下滑 = 把整页缩回封面卡关掉。
    ///
    /// 左右两条通高的带子现在只负责翻页：它们是 `turnZoneRatio` 那两条翻页带最外面的一段。
    /// 以前点这里是唤出按钮，于是翻页带最靠屏幕边的 30pt 被抢走——「点右侧翻页没反应」
    /// 就是点在这一段上（拇指落点天然贴着边）。唤按钮还有一条路：正文中部双击（`handleTap`）。
    ///
    /// 状态栏和 home 指示条那两段不给这两条用——那上面没有按钮，也不该一点就弹东西；
    /// 只有下滑那条手势从屏幕最上沿起手，因为它要的就是「从顶上拉下来」这个动作。
    var edgeZones: some View {

        ZStack {

            HStack {

                leftEdgeStrip

                Spacer()

                edgeStrip(forward: true)
            }
            .frame(maxHeight: .infinity)
            // 顶上一条留给下滑手势，别和它抢落点；底下那截是 home 指示条。
            .padding(.top, ChromeInsets.top + Self.topEdgeHeight)
            .padding(.bottom, ChromeInsets.bottom)

            VStack {

                Color.clear
                    .frame(height: ChromeInsets.top + Self.topEdgeHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: Self.pullThreshold)
                            .onChanged { value in
                                pullChanged(value.translation.height)
                            }
                            .onEnded { value in
                                pullEnded(
                                    translation: value.translation.height,
                                    velocity: value.predictedEndTranslation.height
                                )
                            }
                    )

                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    private func edgeStrip(forward: Bool) -> some View {

        Color.clear
            .frame(width: Self.edgeStripWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                handleEdgeTap(forward: forward)
            }
    }

    /// 左边缘那条额外挂右滑返回。用 simultaneousGesture 而不是 gesture：这条只认横向占优的
    /// 位移，竖着的和轻点一下都还要留给原来那几个手势（翻页、点句朗读、下拉关闭）。
    private var leftEdgeStrip: some View {

        edgeStrip(forward: false)
            .simultaneousGesture(
                DragGesture(minimumDistance: Self.pullThreshold)
                    .onChanged { value in
                        swipeChanged(
                            translation: value.translation.width,
                            height: value.translation.height
                        )
                    }
                    .onEnded { value in
                        swipeEnded(
                            translation: value.translation.width,
                            height: value.translation.height,
                            velocity: value.predictedEndTranslation.width
                        )
                    }
            )
    }

    /// 边缘条的点击：和带子里其余部分同一条路，第一下立刻翻，不等双击窗口（那太迟钝）。
    private func handleEdgeTap(forward: Bool) {

        // 那一划是在滑动，不是点击。
        guard Date().timeIntervalSince(lastSwipeAt) > Self.tapWindow else {
            return
        }

        turnPage(forward: forward)
    }

    /// 下拉关闭走完全程要走多长：屏高的 40%，剩下的交给弹回/关闭两段动画。
    /// 按屏算而不是定死一个数，不然小屏轻轻一划就关，大屏要划到胳膊酸。
    private var pullDistance: CGFloat {
        max(200, pageSize.height * Self.dismissRatio)
    }

    /// 左边缘右滑关闭的全程。比下拉短：横向本来就没那么多行程，
    /// 从屏幕边上划出三分之一已经足够说明「我要走了」。
    private var swipeDistance: CGFloat {
        max(110, pageSize.width * 0.3)
    }

    func pullChanged(
        _ height: CGFloat
    ) {

        // 按钮已经唤出来了：那一下下滑是给工具条用的，不是给关窗用的。
        guard !chromeShown else { return }

        applyPull(
            travel: height,
            distance: pullDistance
        )
    }

    func pullEnded(
        translation: CGFloat,
        velocity: CGFloat
    ) {

        endPull(
            translation: translation,
            velocity: velocity,
            distance: pullDistance
        )
    }

    func swipeChanged(
        translation: CGFloat,
        height: CGFloat
    ) {

        // 只认横向占优的右滑：竖着划不算返回（正文那一面已经不能滚了，竖划本来就没去处，
        // 但这条带子在左边缘，也不该替顶上一条代劳下拉关闭）。
        guard translation > 0, abs(translation) >= abs(height) else { return }

        lastSwipeAt = Date()

        applyPull(
            travel: translation,
            distance: swipeDistance
        )
    }

    func swipeEnded(
        translation: CGFloat,
        height: CGFloat,
        velocity: CGFloat
    ) {

        lastSwipeAt = Date()

        // 落点只看横向：拇指从左下角斜着划出去，累计位移常常竖向更大，
        // 拿「最后是不是横向占优」当开关，就会把已经拉出来的那一下又弹回去。
        guard translation > 0 else {
            retractPull()
            return
        }

        endPull(
            translation: translation,
            velocity: velocity,
            distance: swipeDistance
        )
    }

    /// 两条返回手势共用这一个入口：行程换算成 0...1 喂给 launcher，
    /// 缩回封面卡的那段动画因此和下拉一模一样。
    private func applyPull(
        travel: CGFloat,
        distance: CGFloat
    ) {

        let progress = min(
            1,
            max(0, Double(travel / distance))
        )

        guard progress != pullTravel else { return }

        pullTravel = progress

        launcher.pull(progress)
    }

    private func endPull(
        translation: CGFloat,
        velocity: CGFloat,
        distance: CGFloat
    ) {

        // 几乎没拉开：这一划不算要关窗，弹回去就行。
        guard pullTravel > 0.02 else {
            retractPull()
            return
        }

        let travelled = translation >= distance

        // 没拖满但甩得够远也算这一划：关窗口没人慢慢拖到底。
        let flung = velocity >= distance * 1.2

        pullTravel = 0

        launcher.releasePull(commit: travelled || flung)
    }

    /// 这一划不算返回了：把已经拉出来的那点收回去，别停在半开半合。
    private func retractPull() {

        guard pullTravel > 0 else { return }

        pullTravel = 0

        launcher.releasePull(commit: false)
    }

    func toggleChrome() {

        if chromeShown {
            hideChrome()
        } else {
            showChrome()
        }
    }

    func showChrome() {

        // 下拉拖到一半被别的事件吃掉（没有 onEnded）时，页会停在缩了一半的状态；
        // 任何一次唤出按钮都顺手把它弹回去。
        if pullTravel > 0 {
            pullTravel = 0
            launcher.releasePull(commit: false)
        }

        chromeVisible = true
        scheduleChromeExpiry()
    }

    func hideChrome() {

        chromeVisible = false
        showTypography = false
        chromeExpiry?.cancel()
        chromeExpiry = nil
    }

    /// 几秒后收回。Aa 面板开着的时候不收回，否则用户字号调到一半条就没了。
    func scheduleChromeExpiry() {

        chromeExpiry?.cancel()

        chromeExpiry = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.chromeAutoHide * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            if showTypography {
                scheduleChromeExpiry()
            } else {
                chromeVisible = false
            }
        }
    }
}
