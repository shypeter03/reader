//
//  Chapter.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

enum AudioGenerationStatus: String, Codable, Sendable {
    case pending
    case analyzing
    case generating
    case completed
    case failed
}

/// 正文、AI 标注与音频是三份独立资源；任何增强资源失败都不能阻塞正文。
enum TextStatus: String, Codable, Sendable { case available }
enum AnalysisStatus: String, Codable, Sendable { case pending, running, completed, failed }
enum TTSStatus: String, Codable, Sendable { case pending, running, partial, completed, failed }

/// 图片提取的口径版本。判据（独占一段、尺寸下限、锚点算法）一改就抬它，
/// 落库那份对不上就回 parser 重解一次。
///
/// 刻意**不**跟着 `SentenceSplitter.textVersion` 走：图片不进句序，重解出来的句子和上一版
/// 逐字相同，句子的 `deterministicID` 因此一根手指都没碰——抬 `textVersion` 等于把全书音频作废。
enum ImageExtraction {

    /// 2：`</p><img/><p>` 这种不写空行的源文件（calibre 生成的网文普遍如此）以前会把哨兵
    /// 挤进前一段那一行——段落边界被 `joiningSoftLineBreaks` 当段内折行接掉，锚点也就退到
    /// 前一段的头顶（我欲封天实测 117 处，与 `ChapterImage.anchor` 记的口径相反）。
    /// 现在独占一块的图自己占一行，锚点回到「图之后第一个段落」；老那份锚点全是偏的，重解。
    static let version = 2
}

/// EPUB 里写的是相对路径的 href，机器上走的是绝对路径的 URL，这一层把前者换成后者。
///
/// 放在 Models 而不是解析器里：书单（`Book.placedImages`）在**读**的那一侧也要按同一个式子
/// 归一张图的 key，而书单不许倒过来依赖 `EPUBParser`（它 `import ZIPFoundation`，
/// 排版那条探针链没有这个模块，编不过）。
enum EPUBHref {

    static func resolve(
        href: String,
        relativeTo baseURL: URL
    ) -> URL {

        let cleanHref =
            href
                .removingPercentEncoding
            ?? href

        return baseURL
            .appendingPathComponent(
                cleanHref
            )
            .standardizedFileURL
    }
}

/// 正文里的一张图在纸上的位置。
///
/// 图片**不进句序**：解析时它换成一个哨兵行，量完锚点就把哨兵摘掉，剩下的句子照常连续编号。
/// 于是「有图」和「无图」两版切出来的句子一模一样（`.probe/image-anchor-probe.swift` 逐章比过），
/// 朗读、标注、已有音频都不受影响；图上纸只是多出来的一块高度，不占句子、不被朗读。
struct ChapterImage: Equatable, Hashable, Codable, Sendable {

    /// `<img src>` 的原样值（相对本节的章文件）。落库不许存绝对路径：容器一变路径就失效
    /// （#29 那类「重新部署后正文读不到」），用的时候由 `ChapterDescriptor.fileURL` 现解。
    var href: String

    /// 锚：这一张排在 `sentences[anchor]` **之前**。
    ///
    /// 恒等于图中那一段之后第一个段落的首句下标，也就是「图注那一句」——图因此压在
    /// 自己的图注头顶，图注仍是正文里的一句，能点、能读，不必另存一份（存两份就会有一版漂）。
    ///
    /// `anchor == sentences.count` = 图在章末，后面没有句子了，画在最后一句**之后**。
    var anchor: Int

    /// 原图像素尺寸。解析期只用 ImageIO 读文件头（不解码像素），所以点开一章还是那一秒预算。
    /// 读不到就整张不要了：尺寸不知道，排版没法给它留框，画出来只能是溢出纸外的一团。
    var pixelWidth: Int

    var pixelHeight: Int

    // MARK: - 上不上纸的口径

    /// 这一组是**写路径与读路径共用**的口径：种重复率表的是解析器（`EPUBParser`），
    /// 用它筛的是书单（`Book.placedImages`），两端各写一份迟早分家——
    /// 「书单记的张数」和「送去排的张数」一旦不同，纸上的图就比量到的多，那一面超页。
    ///
    /// 放在 Models 而不是解析器里，是因为读路径那一侧不能依赖 `EPUBParser`（见 `EPUBHref`）。

    /// 图的最小边长（像素）。短边不到这一格的不是插图：16×16 的项目符号、600×57 的装饰线、
    /// 150×53 的小图标（亲密关系实测三种都有）。它们上了纸就是一块没有内容的白框。
    static let minimumImageEdge = 64

    /// 同一张图在**全书多少章里出现过**。达到章数四分之一就当装饰图跳过。
    ///
    /// 为什么按「重复率」而不是按文件名猜：网文的书壳图每一章都贴一张（我欲封天 602 枚 logo、
    /// 庆余年 387 枚），而出版社书的真图一张只出现一次（亲密关系 190 张各不相同）。
    /// 重复率把这两类一刀切开，不需要维护任何「log1.jpg / yw.png」那种名单。
    ///
    /// 三道闸一起才算装饰：书够长（≥8 章）、出现够多（≥4 章）、且占比够高（≥25%）。
    /// 少了前两条，一本八页图文小书里「跨页拼的一张图」会被当成装饰删掉——那正是它全部内容。
    static func isDecorativeImage(
        occurrences: Int,
        chapterCount: Int
    ) -> Bool {
        chapterCount >= 8
            && occurrences >= 4
            && occurrences * 4 >= chapterCount
    }

    /// 一张图归一化成什么字符串去对重复率表。
    ///
    /// 按「上级目录名/文件名」而不是原 src：同一枚 logo 在 `Text/Ch0001.html` 里写
    /// `../Images/log1.jpg`、在 `Text/01.html` 里可能写 `../Images/./log1.jpg`，
    /// 字面不同、文件是同一个。先按章目录解成绝对路径（顺带 percent 解码），
    /// 再取回「倒数第二段 + 文件名」，两本目录布局不同的书也不会串味。
    static func imageKey(
        href: String,
        chapterURL: URL
    ) -> String {
        let resolved = EPUBHref.resolve(
            href: href,
            relativeTo: chapterURL.deletingLastPathComponent()
        )
        let directory = resolved.deletingLastPathComponent().lastPathComponent
        return directory.isEmpty
            ? resolved.lastPathComponent
            : "\(directory)/\(resolved.lastPathComponent)"
    }
}

struct Chapter: Identifiable, Codable, Sendable {

    let id: UUID

    var index: Int

    var title: String

    var sentences: [Sentence]

    var characters: [Character]

    var audioStatus: AudioGenerationStatus

    var textStatus: TextStatus
    var analysisStatus: AnalysisStatus
    var ttsStatus: TTSStatus

    /// 正文是按哪一版断句规则切出来的。读路径会直接用落库的正文，不再每次点开
    /// 都跑 parser，所以规则一变就得有个东西认出旧数据——对不上的章节重解析一次。
    var textVersion: Int

    /// 「这句是谁说的」是按哪一版说话人提取口径算出来的（``DialogueAttribution/annotationVersion``）。
    /// 和 textVersion 分开记：提取口径改了不必重切正文，只重算说话人，
    /// 情绪参数与已有音频都留着——声音变了的句子交给漂移分支单独退回重录。
    var annotationVersion: Int

    /// 这一章是一张卷扉页（「第一卷 在澹州」那种单独占一面、除了卷名什么都没有的纸）。
    ///
    /// 为什么要单独记：判据在**正文**里（提不出正文才算扉页），只有 `loadChapter` 那一趟知道，
    /// 而渲染端必须认出它才不会画「这一章没有可朗读的正文」那句提示——那是给真·空章（图片章）
    /// 准备的，画在卷名页上就成了「这页坏了」。
    /// 扉页一律零句：不排产、不朗读，分页端按 `pages.isEmpty` 那条兜底交出一面纸。
    ///
    /// nil 和 false 不是一回事：nil = 这份 `chapter.json` 是在这条规则之前落的，那时候的结论
    /// 根本不存在，读路径必须回 parser 重判一次（`loadParsedChapter` 与 `BookPagination` 都按
    /// 这一条走）；false = 重判过、确实不是扉页。所以只有解码这条路给得出 nil，
    /// 代码里新建的 Chapter 一律是 false。
    var isVolumeDivider: Bool?

    /// 这一章正文里的图（已经过「独占一段 + 尺寸下限」这道闸，见 `EPUBParser.imageAnchors`）。
    ///
    /// 是不是装饰图**不在这里判**：那条要全书的重复率，而这一份是逐章落的，判在这里就得
    /// 为一次统计改动重解整本书。装饰图那张表记在 `Book.imageTally`，用量的一侧
    /// （分页、排版）现查。
    var images: [ChapterImage]

    /// `images` 是按哪一版提取口径算的。缺字段 = 老数据，读路径回 parser 重解一次。
    var imagesVersion: Int

    init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        sentences: [Sentence] = [],
        characters: [Character] = [],
        audioStatus: AudioGenerationStatus = .pending,
        textStatus: TextStatus = .available,
        analysisStatus: AnalysisStatus = .pending,
        ttsStatus: TTSStatus = .pending,
        textVersion: Int = SentenceSplitter.textVersion,
        annotationVersion: Int = DialogueAttribution.annotationVersion,
        isVolumeDivider: Bool = false,
        images: [ChapterImage] = [],
        imagesVersion: Int = ImageExtraction.version
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.sentences = sentences
        self.characters = characters
        self.audioStatus = audioStatus
        self.textStatus = textStatus
        self.analysisStatus = analysisStatus
        self.ttsStatus = ttsStatus
        self.textVersion = textVersion
        self.annotationVersion = annotationVersion
        self.isVolumeDivider = isVolumeDivider
        self.images = images
        self.imagesVersion = imagesVersion
    }

    enum CodingKeys: String, CodingKey {
        case id, index, title, sentences, characters, audioStatus
        case textStatus, analysisStatus, ttsStatus, textVersion, annotationVersion
        case isVolumeDivider, images, imagesVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        index = try c.decode(Int.self, forKey: .index)
        title = try c.decode(String.self, forKey: .title)
        sentences = try c.decode([Sentence].self, forKey: .sentences)
        characters = try c.decode([Character].self, forKey: .characters)
        audioStatus = try c.decodeIfPresent(AudioGenerationStatus.self, forKey: .audioStatus) ?? .pending
        textStatus = try c.decodeIfPresent(TextStatus.self, forKey: .textStatus) ?? .available
        analysisStatus = try c.decodeIfPresent(AnalysisStatus.self, forKey: .analysisStatus) ?? .pending
        ttsStatus = try c.decodeIfPresent(TTSStatus.self, forKey: .ttsStatus) ?? .pending
        // 缺字段就是「规则改过之前存的」，不能沿用当前版本号：兜底成 0 让它重解析一次。
        textVersion = try c.decodeIfPresent(Int.self, forKey: .textVersion) ?? 0
        annotationVersion = try c.decodeIfPresent(Int.self, forKey: .annotationVersion) ?? 0
        isVolumeDivider = try c.decodeIfPresent(Bool.self, forKey: .isVolumeDivider)
        images = try c.decodeIfPresent([ChapterImage].self, forKey: .images) ?? []
        imagesVersion = try c.decodeIfPresent(Int.self, forKey: .imagesVersion) ?? 0
    }
}
