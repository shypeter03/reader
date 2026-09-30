//
//  CharacterRoster.swift
//  Reader
//
//  一本书的人物声音档案：名字 → 性别 + 那把固定的声音。
//
//  为什么要有档案，而不是「每章各自判」：章内判出来的性别只覆盖这一章，同一张脸
//  在第 3 章被判成男、在第 40 章被判成女，那人就两句换个嗓——而音频是按句缓存的，
//  错的那半本书还得重录。所以档案的口径是**定过就不改口**：
//
//  - 一个人的性别一旦判出就钉死，后面的扫描只补那些还没判出来的人（见 `merge`）；
//  - 还没判出来的名字先落在默认嗓上，等后台把整本书扫完再钉；那一刻它早录的那几句
//    会被 ``ReaderPipeline`` 的漂移分支认出来、退回重录，不会出现半本书两种嗓；
//  - 声音由 ``CharacterAnalysis`` 给的性别 + 名字稳定散列决定，是纯函数，
//    所以清完缓存重扫也得到同一份分配；
//  - 档案住在书自己的解析目录（`cache/novel/{bookID}/roster.json`），
//    「清空音频与标注」把它一起带走——音频树同时没了，两边一起重来才不会出现
//    半本书旧嗓半本书新嗓。
//

import Foundation

final class CharacterRoster: @unchecked Sendable {

    static let shared = CharacterRoster()

    /// 档案口径的版本。**改了性别判定规则、说话人提取口径、或者动了 VoiceManager 的声音池
    /// 就要 +1**：留着旧档案的话，新书按新规则判、老书按老档案读，同一本书里就混出两种口径。
    ///
    /// 3：性别证据改成「紧贴名字」（旧的同句投票会把男主判成女的），
    /// 同时候选人名加了首字姓表——旧档案里那些人的性别多半是投错的，整份作废重来。
    ///
    /// 4：代词证据只认主语位置（「苏檀儿望着他」的他是另一个人，旧版给他俩都投男票，
    /// 实测赘婿女主拿到 男50/女47 被判成男的），并且姓表里挪掉了只当复姓首字才作数的字。
    /// 这两条都改**判定**，钉过性别的旧档案必须整份作废。
    ///
    /// 5：姓表补上漏掉的常用姓（岳薛柳元尹穆雷段纪舒尚单岑凌滕焦闵）与群体头「众」。
    /// 这一条改的是**谁进档案**，旧档案少了几个人，那几个人的台词一直压在无名嗓上。
    ///
    /// 6：代词证据两处。①收紧成「名字和代词都得站在**话题位**（分句开头）」——旧口径只挡得住
    /// 「及物动词+了着过+代词」，动词表是闭口的，庆余年实测女角**全**被判男
    /// （林婉儿 男15/女4）：「林婉儿啐了他一口」这种宾语「他」全记成了她的男票。
    /// ②补一条「承前主语」：本句没有名字、开头是 他/她，而上一句只有一个当主语的名字，
    /// 那个代词就接着说他——赘婿实测出场 70 次的苏仲堪、58 次的李频在旧口径下一张票都捞不着。
    /// 另外候选名闸门补了前缀残渣（盘龙 梅丽/梅丽特、艾丽/艾丽斯 是同一个人两把嗓）。
    /// 判定和入档都改了，旧档案整份作废重扫。
    ///
    /// 7：入档闸门改成**按全书累计**。旧口径把「说过两次话、被称呼过一次」算在每一批里，
    /// 而设备是按 7 章一轮扫的，于是每章只说一次话的人轮轮不达标——绍宋实测 7 章入档 0 人、
    /// 整本一次扫 111 人，听感就是「所有配角一把无名男嗓」。现在档案里带一本证据账本
    /// （`tallies`），票数也按累计判，所以旧档案那份「谁够格」的名单是错的，整份作废。
    /// 同批还并了三条改了**谁算一个人**的口径：官称进 ``DialogueAttribution/relationTitles``
    /// （小林学士并到小林）、名字里只许有汉字（治「大（上白」）、女称谓补「后/贵妃/帝姬/娘子」
    /// （绍宋判出的 52 人里女的是 0）。旧档案里那些「一个人拆成两个」的条目留着就混口径。
    ///
    /// 8：三件事，都改**谁落到哪把嗓**。①称谓残渣收尾（``CharacterAnalysis`` 的 `untailGenderTitle`）：
    /// 「郑太后身」「吴贵妃面」这种尾巴带一截状语的串以前切不动，于是书里的女角一句都没进过档案
    /// ——绍宋 437 章判出 57 个性别里女只有 1 个，那几句台词全压在男嗓上。现在它们收进真名，
    /// 入档名单会变。②独指称呼并档（`aliases`，赵官家→赵玖）与前缀残渣并档（``fragmentAliases``，
    /// 林景→林景默）：同一个人两个写法两把嗓，老档案里没有这些映射，那 128 句「赵官家道」和
    /// 「林景」那 11 句一直挂在另一把嗓上。
    /// ③段内承前的书级开关（`quoteUnbalanced`/`quoteTotal`/`quoteClean` 三个新字段）：门槛按
    /// **段落**数引号，不是按句子——断句器本来就把一段台词切成几句，按句子数会把每本正常排版的书
    /// 都判成劣化（绍宋实测句子级 23.9%、段落级 0.0%），承前就永远开不了。
    /// 旧的 `complete` 档案不许再动（``merge`` 早退），这三条只能靠作废重扫生效。
    ///
    /// 9：「判不出性别的人」不再钉一把独立的无名嗓，改钉**旁白那把**
    /// （``VoiceManager/voiceForCharacter(name:gender:)`` 的 `.unknown` 分支）。这一条改
    /// **谁落到哪把嗓**，而 `voiceID` 是存进档案的：留着旧档案，那些人会继续带着 Ryan 出门，
    /// 书里就还是「旁白中间换人」。旧档案整份作废重扫。
    static let scheme = 9

    struct Person: Codable, Hashable {
        let name: String
        let gender: Gender
        /// 钉下来的声音身份（``VoiceManager`` 那套 speaker 名）。存下来而不是每次现算：
        /// 以后往池子里加一把声音，不会把已有这本书的人改嗓。
        let voiceID: String
        let maleVotes: Int
        let femaleVotes: Int
        let mentions: Int
    }

    private struct Snapshot: Codable {
        var scheme: Int
        /// 已经扫过的章数（只是给人看的进度，判定不靠它）。
        var scannedChapters: Int
        /// 整本书扫完了没。扫完就不再有任何扫描动这份档案。
        var complete: Bool
        var people: [Person]
        /// 每个候选串在**全书**攒到的证据：说过几次话、被人称呼过几次、男女票、出场次数。
        ///
        /// 为什么要存下来：扫描是一批一批喂进来的（设备 7 章一轮），而「说过两次话」这道
        /// 闸门必须按整本书算。不记账的话每章只说一次话的人轮轮不达标——绍宋实测 7 章
        /// 一轮入档 0 人、整本一次扫 111 人，差的正是这一条。
        ///
        /// 还没达标的名字也记着（它们只在攒证据，不进 `people`，所以查不到嗓），
        /// 数量按 ``maxTallies`` 截断：一本书的候选串成千上万，全存会把 roster.json 撑爆。
        var tallies: [Tally]
        /// 别名 → 档案里真名的映射，只在**整本书扫完**那一次算出来（见 ``soleRoleAliases``）。
        ///
        /// 为什么存盘而不是现算：并档要的是全书累计的证据（赵官家被当面叫过 1892 次、
        /// 同姓里赵玖的出场是第二名的 9 倍），而这些数字在头几批 7 章里根本还不存在。
        /// 档案扫完就不许再动（``merge`` 在 `complete` 时早退），所以这个决定必须跟着档案落盘。
        var aliases: [String: String]
        /// 扫过的段落里「带引号」与「引号不成对」的累计数，用来定这本书能不能段内承前
        /// （见 ``CharacterAnalysis/carriedSpeaker(at:texts:paragraphStarts:knownNames:rosterName:enabled:)``）。
        ///
        /// 为什么按段落而不是按句子：断句器会把一段台词切成几句，只有头一句带「“」、末一句带「」」，
        /// 按句子数会把每一本正常排版的书都判成劣化（绍宋实测句子级 23.9%、段落级 0.0%）。
        /// 为什么要攒着而不是每批现算：设备是按 7 章一轮喂进来的，头几批样本薄，
        /// 那点数字分不出这本书是不是**系统性地**漏闭引号。攒够 ``minQuoteSample`` 段就
        /// **一次性**钉下来，钉过不再改——承前与否直接决定句子的归属，翻来覆去就是同一句两种嗓。
        var quoteUnbalanced: Int
        var quoteTotal: Int
        /// 钉下来的结论。nil = 还没攒够样本，此时**不借**（保守）。
        var quoteClean: Bool?
    }

    /// 一个候选名的累计证据。`name` 是 ``CharacterAnalysis`` 折过残渣后的那一截。
    struct Tally: Codable {
        var name: String
        var speaks: Int
        var addressed: Int
        var maleVotes: Int
        var femaleVotes: Int
        var mentions: Int
    }

    /// 证据账本的条数上限。够不下了先丢存在感最低的那些：一本书真正说话超过两次的人
    /// 通常一两百个，剩下的长尾只是占盘。
    private static let maxTallies = 600

    /// 定「引号配对干净不干净」所需的最少带引号**段落**数。攒够了就把结论钉死，不再改。
    /// 200 段是这么定的：7 章一轮的窗口实测能出上百个台词段（绍宋 60 章 1276 段），
    /// 所以最迟两三轮就有结论，而再少的样本里「偶发漏一个闭引号」和「这本书系统性不闭合」分不开。
    private static let minQuoteSample = 200

    private struct Loaded {
        var snapshot: Snapshot?
        /// 按长度倒序，好让「韩立师兄」先撞上「韩立」这种更短的真名。
        var byName: [String: Person]
        var namesByLength: [String]
        var aliases: [String: String]
    }

    private let lock = NSLock()
    private var cache: [UUID: Loaded] = [:]

    private init() {}

    // MARK: - 读

    /// 这本书的档案是不是已经扫完整本书并落盘。没扫完也照样能用（`person` 查得到多少算多少）。
    func isBuilt(bookID: UUID) -> Bool {
        let loaded = snapshot(bookID: bookID)
        return loaded.snapshot?.scheme == Self.scheme && loaded.snapshot?.complete == true
    }

    /// 这本书允不允许「段内承前」借说话人（见 ``CharacterAnalysis/carriedSpeaker(at:texts:paragraphStarts:knownNames:rosterName:enabled:)``）。
    ///
    /// 结论来自档案里累计的引号配对样本：**没攒够样本一律返回 false**。宁可有一句台词退回
    /// 那把一致的无名嗓，也不要在排版劣化的书上把 A 的台词安上 B 的腔调——后者听起来就是 bug。
    func allowsParagraphCarry(bookID: UUID) -> Bool {
        snapshot(bookID: bookID).snapshot?.quoteClean == true
    }

    /// 已经攒到的引号配对样本，只进日志（`[Roster]` 用它说明这本书为什么开/关承前）。
    func quotePairing(bookID: UUID) -> CharacterAnalysis.QuotePairing {
        let written = snapshot(bookID: bookID).snapshot
        return CharacterAnalysis.QuotePairing(
            unbalanced: written?.quoteUnbalanced ?? 0,
            total: written?.quoteTotal ?? 0
        )
    }

    /// 档案里的「独指称呼 → 真名」映射（见 ``soleRoleAliases``）。查声那条 ``person`` 已经用上了，
    /// 这里只是给 `[Roster]` 日志与真书探针看见它到底并了几条。
    func aliasMap(bookID: UUID) -> [String: String] {
        snapshot(bookID: bookID).snapshot?.aliases ?? [:]
    }

    /// 这个人在这本书里用哪把声音。查不到（档案还没建、这个名字没说过话）返回 nil，
    /// 由调用方退回章内 Character 的老口径。
    func voice(bookID: UUID, name: String) -> String? {
        person(bookID: bookID, name: name)?.voiceID
    }

    /// 档案里已有的名字，给「同句已知人名」那次放宽当候选池（见
    /// ``DialogueAttribution/personName(in:knownNames:)``）。
    ///
    /// 池子只许来自档案而不是现从字面上猜：档案这两道闸门（首字得是姓、全书说过两次话）
    /// 正是放宽能成立的前提——不然「扭头」「淡然」这种残渣会被当成人，把一堆不同人的
    /// 台词并到同一把嗓上。
    func names(bookID: UUID) -> Set<String> {
        Set(snapshot(bookID: bookID).snapshot?.people.map(\.name) ?? [])
    }

    func person(bookID: UUID, name: String) -> Person? {
        let loaded = snapshot(bookID: bookID)
        let canonical = DialogueAttribution.canonicalName(name)
        // 别名排在最前面：并过档的那个人（赵官家）在档案里仍留着自己那一条，先查它的话
        // 「同一个人两把嗓」就原样留在听感里——而这条正是并档要治的。
        if let target = loaded.aliases[canonical], let hit = loaded.byName[target] { return hit }
        if let hit = loaded.byName[canonical] { return hit }
        // 查表方向和扫书归并必须同一套口径，否则句子上挂着「韩立师兄」「赵玖背身」
        // 这种写法时，档案里明明有这个人却查不到 → 那几句退回默认嗓，正是「一个人两个声音」。
        let stem = DialogueAttribution.stem(canonical)
        if stem != canonical, let hit = loaded.byName[stem] { return hit }
        // 前缀方向：长的那截是剥不干净的状语，短的那截才是书里的人（从最长试起）。
        if canonical.count > DialogueAttribution.minNameLength {
            for length in stride(from: canonical.count - 1, through: DialogueAttribution.minNameLength, by: -1) {
                if let hit = loaded.byName[String(canonical.prefix(length))] { return hit }
            }
        }
        // 后缀方向：提示语最多吃进 12 个字，「只见韩立」这种修饰在前的写法并到「韩立」。
        for candidate in loaded.namesByLength where canonical.hasSuffix(candidate) {
            return loaded.byName[candidate]
        }
        return nil
    }

    // MARK: - 写

    /// 把一轮扫描的结果并进档案。返回是不是真的动了。
    ///
    /// 只补两种空：档案里还没有的名字、以及还没判出性别的人。已经判出性别的一个字都不改
    /// ——改口就意味着那个人在这本书里已经录过的每一句都要重录，而证据再多也不值得。
    @discardableResult
    func merge(
        bookID: UUID,
        people: [CharacterAnalysis.Person],
        scannedChapters: Int,
        complete: Bool,
        quotes: CharacterAnalysis.QuotePairing
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var loaded = cache[bookID] ?? Loaded(snapshot: nil, byName: [:], namesByLength: [], aliases: [:])
        if loaded.snapshot == nil { loaded.snapshot = read(bookID: bookID) }
        var written = loaded.snapshot
            ?? Snapshot(scheme: Self.scheme, scannedChapters: 0, complete: false,
                        people: [], tallies: [], aliases: [:], quoteUnbalanced: 0, quoteTotal: 0, quoteClean: nil)
        // 旧口径的档案整份作废：它上面那些人的性别是按老规则判的，留着就混口径。
        if written.scheme != Self.scheme {
            written = Snapshot(
                scheme: Self.scheme, scannedChapters: 0, complete: false,
                people: [], tallies: [], aliases: [:], quoteUnbalanced: 0, quoteTotal: 0, quoteClean: nil
            )
        }
        guard !written.complete else { return false }

        var byName = Dictionary(written.people.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        var tallies = Dictionary(written.tallies.map { ($0.name, $0) }, uniquingKeysWith: { $1 })

        for person in people {
            var tally = tallies[person.name]
                ?? Tally(name: person.name, speaks: 0, addressed: 0,
                         maleVotes: 0, femaleVotes: 0, mentions: 0)
            tally.speaks += person.attestations
            tally.addressed += person.addressed
            tally.maleVotes += person.maleVotes
            tally.femaleVotes += person.femaleVotes
            tally.mentions += person.mentions
            tallies[person.name] = tally

            if let existing = byName[person.name] {
                // 钉过性别的人不改口；还没钉的用**累计**票再判一次，攒够 2 票才钉。
                guard existing.gender == .unknown else { continue }
                let judged = CharacterAnalysis.gender(male: tally.maleVotes, female: tally.femaleVotes)
                guard judged != .unknown else { continue }
                byName[person.name] = Person(
                    name: person.name,
                    gender: judged,
                    voiceID: VoiceManager.voiceForCharacter(name: person.name, gender: judged),
                    maleVotes: tally.maleVotes,
                    femaleVotes: tally.femaleVotes,
                    mentions: tally.mentions
                )
                continue
            }
            // 新人入档要同时有两条独立证据：说过两次话、也被人当人称呼过（后者是句法位置的
            // 闸门，专治首字姓表放行的状语残渣）。两条都按全书累计，所以「这章说一次、
            // 下章说一次」的人也算说过两次。
            //
            // 例外：**字面里带性别称谓**的人说过一次话就收（绍宋实测，女角几乎不会被写成
            // 「郑太后道：“…”」这种形状，两道闸门一起把书里所有女人拦在档案之外，
            // 那几句落到她们身上的台词便全压在男嗓上）。称谓是闭口集合，「她是谁」写在字面上。
            let titled = CharacterAnalysis.hasGenderTitle(person.name)
            guard tally.speaks >= (titled ? 1 : CharacterAnalysis.minSpeakerAttestations),
                  titled || tally.addressed >= 1 else { continue }
            let judged = CharacterAnalysis.gender(male: tally.maleVotes, female: tally.femaleVotes)
            byName[person.name] = Person(
                name: person.name,
                gender: judged,
                voiceID: VoiceManager.voiceForCharacter(name: person.name, gender: judged),
                maleVotes: tally.maleVotes,
                femaleVotes: tally.femaleVotes,
                mentions: tally.mentions
            )
        }

        written.people = Array(byName.values).sorted { $0.name < $1.name }
        // 别名并档只在**整本书扫完**那一次算：它要的证据是全书累计的（这个称呼被人当面叫过
        // 多少次、同姓里谁压倒性最活跃），头几批 7 章里那些数字还不存在。算完跟着 `complete`
        // 一起钉死——档案之后不再动，而早期已经按别名前那条嗓录好的句子，由 ``ReaderPipeline``
        // 的漂移分支认出来退回重录，不需要在这里额外做什么。
        if complete {
            var aliases = soleRoleAliases(byName: byName, tallies: tallies)
            for (fragment, person) in fragmentAliases(byName: byName) where aliases[fragment] == nil {
                aliases[fragment] = person
            }
            written.aliases = aliases
        }
        // 已入档的人的账本要继续留着（他可能还没判出性别，后面几轮靠这些票钉）；
        // 装不下的长尾先丢「既没说过几次话、也没被叫过几次」的那些。
        var kept = Array(tallies.values)
        if kept.count > Self.maxTallies {
            kept = Array(kept.sorted {
                let lhs = $0.speaks + $0.addressed + $0.mentions
                let rhs = $1.speaks + $1.addressed + $1.mentions
                return lhs != rhs ? lhs > rhs : $0.name < $1.name
            }.prefix(Self.maxTallies))
        }
        written.tallies = kept.sorted { $0.name < $1.name }
        written.scannedChapters = max(written.scannedChapters, scannedChapters)
        // 引号配对的样本按累计攒，攒够就把结论钉死一次，之后不再改（理由见 Snapshot 那条注释）。
        written.quoteUnbalanced += quotes.unbalanced
        written.quoteTotal += quotes.total
        if written.quoteClean == nil, written.quoteTotal >= Self.minQuoteSample || complete {
            written.quoteClean = CharacterAnalysis.QuotePairing.isClean(
                CharacterAnalysis.QuotePairing(
                    unbalanced: written.quoteUnbalanced, total: written.quoteTotal
                )
            )
        }
        written.complete = written.complete || complete

        loaded.snapshot = written
        index(&loaded, snapshot: written)
        cache[bookID] = loaded
        write(bookID: bookID, snapshot: written)
        return true
    }

    /// 「清空音频与标注」之后必须丢掉内存里的那份：磁盘上的档案已经跟着解析树删了，
    /// 留着这一份会让下一轮扫书被它的闸门挡住。
    func forget(bookID: UUID) {
        lock.lock()
        cache[bookID] = nil
        lock.unlock()
    }

    // MARK: - 内部

    private func snapshot(bookID: UUID) -> Loaded {
        lock.lock()
        defer { lock.unlock() }
        if let loaded = cache[bookID] { return loaded }
        var loaded = Loaded(snapshot: read(bookID: bookID), byName: [:], namesByLength: [], aliases: [:])
        if let written = loaded.snapshot { index(&loaded, snapshot: written) }
        cache[bookID] = loaded
        return loaded
    }

    private func index(_ loaded: inout Loaded, snapshot: Snapshot) {
        // uniquing 而不是 uniqueKeysWithValues：档案是磁盘上的一份 JSON，重名只是数据脏，
        // 不该让读它的每一次（合成每一句都要查）当场崩。
        loaded.byName = Dictionary(snapshot.people.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        loaded.namesByLength = snapshot.people.map(\.name).sorted { $0.count > $1.count }
        loaded.aliases = snapshot.aliases
    }

    /// 一个「姓 + 独指称呼」要并到同姓那个人身上，得同时满足四条，缺一条就不并（宁缺不错）：
    ///
    /// 1. 称呼在 ``CharacterAnalysis/soleRoleTitles`` 那张闭口表里（一本书只有一个主人：官家、
    ///    太后、丞相…）。「大人/将军/先生」绝不在内，谁都能被这么叫。
    /// 2. 这个称呼**确确实实被人当面叫过**够多次（``minAliasAddressed``）。它必须在书里是一个
    ///    真的称呼，而不是某个名字的巧合尾巴。
    /// 3. 同姓的人里，目标必须**压倒性**最活跃（出场 ≥ 第二名的 3 倍）。绍宋实测：赵玖 4936 /
    ///    赵鼎 540 = 9.1 倍，赵官家并到赵玖 ✓；而吕相公那边 top1 是残渣「吕好」（788，
    ///    其实是吕好问被 ``DialogueAttribution/canonicalName`` 剥掉了「问」），吕颐浩只排第二
    ///    （464），1.7 倍——**拒并**。宁可在听感上多留一把嗓，也不把两个真人并成一把。
    /// 4. 性别对得上（称呼的字面性别 = 目标已钉的性别）。判不出性别的人不当并档目标：
    ///    并过去就等于顺手给他钉了嗓，而钉错要重录整本。
    ///
    /// 失败模式写在这里：独指假设可能不成立（一本书里两个贵妃、太后与 top1 不同姓），
    /// 所以第 3、4 条是硬闸门，而默认动作是不并。真书探针会把每一条实际发生的并档打印出来逐条人眼看。
    private func soleRoleAliases(
        byName: [String: Person],
        tallies: [String: Tally]
    ) -> [String: String] {
        var aliases: [String: String] = [:]
        for (name, source) in byName.sorted(by: { $0.key < $1.key }) {
            guard let surname = CharacterAnalysis.soleRoleSurname(of: name),
                  source.gender != .unknown,
                  (tallies[name]?.addressed ?? 0) >= Self.minAliasAddressed else { continue }
            let rivals: [Person] = byName.values.filter { other in
                other.name != name
                    && other.name.hasPrefix(surname)
                    && other.gender == source.gender
                    && !CharacterAnalysis.hasGenderTitle(other.name)
                    && aliases[other.name] == nil
            }
            let ranked = rivals.sorted { lhs, rhs in
                if lhs.mentions != rhs.mentions { return lhs.mentions > rhs.mentions }
                return lhs.name < rhs.name
            }
            guard let top = ranked.first else { continue }
            let runnerUp = ranked.dropFirst().first?.mentions ?? 0
            guard top.mentions >= Self.aliasDominance * max(1, runnerUp) else { continue }
            aliases[name] = top.name
        }
        return aliases
    }

    /// **前缀残渣**并档：档案里「短的那截」如果几乎只是「长的那截」被提示语吃掉一个字留下的
    /// 碎片，它就不是另一个人。
    ///
    /// 实测的病灶（绍宋 437 章）：书里只有「林景默」这一个近臣，而档案里同时站着「林景」（被认作
    /// 说话人 11 次）和「林景默」，两条记录两把嗓——同一个人口里的两段对话换了声音，正是需求里
    /// 禁止的那件事。``DialogueAttribution/canonicalName`` 只能往短的方向折（切状语尾巴），
    /// 碰上「林景默」这种本身是完整三字名的串就没法知道该并回去，所以这一步只能在**全书证据**上做。
    ///
    /// 判据只用档案已有的两个 `mentions`（在遮掉台词的正文里数子串，长名的每一次都含一次短名），
    /// 于是短名**独立**出现的次数 ≈ `short.mentions - long.mentions`：
    ///
    /// 1. 长的那截自己得在书里出现过 ``minFragmentMentions`` 次以上——不然它自己才是残渣，
    ///    该并的方向反过来。
    /// 2. 短的那截独立出现的次数既 ≤ 长名出现次数的二十分之一，绝对上也不超过
    ///    ``maxFragmentStandalone`` 次。绍宋：林景 183 − 林景默 181 = 独立 2 次（1.1%），并；
    ///    而一个真有 5 次单独出场、对面叫 100 次的名字（1/20 刚好压线）会被绝对上限放行、
    ///    一个单独出场 20 次的绝不并。宁缺不错：多留一把嗓只是听感重复，并错人是把两个真人合成一个。
    /// 3. 只往出场最多的那截并，且目标自己不再是被并走的人（免得出现 甲→甲乙→甲乙丙 这种一跳
    ///    查不到的链）。
    ///
    /// 失败模式写在这里：一本书里真有两个人，一个的名字恰好是另一个的前缀，而短的那个又几乎不
    /// 单独出现——那种书会把两人并成一把嗓。所以闸门比独指称呼那条紧一个量级（1/20 再卡绝对上限），
    /// 默认动作是不并，探针把每一条实际发生的并档连出场数一起打出来逐条人眼看。
    private func fragmentAliases(byName: [String: Person]) -> [String: String] {
        var aliases: [String: String] = [:]
        // 长名先判：短的那截要并的目标此刻已经知道自己有没有被并走。
        let order = byName.keys.sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs < rhs
        }
        for short in order {
            guard let source = byName[short] else { continue }
            let longer: [Person] = byName.values.filter { other in
                other.name.count > short.count && other.name.hasPrefix(short)
            }
            let ranked = longer.sorted { lhs, rhs in
                if lhs.mentions != rhs.mentions { return lhs.mentions > rhs.mentions }
                return lhs.name < rhs.name
            }
            guard let top = ranked.first, aliases[top.name] == nil else { continue }
            guard top.mentions >= Self.minFragmentMentions else { continue }
            let standalone = max(0, source.mentions - top.mentions)
            guard standalone <= Self.maxFragmentStandalone,
                  Self.fragmentDominance * standalone <= top.mentions else { continue }
            aliases[short] = top.name
        }
        return aliases
    }

    /// 称呼被当面叫过的最少次数。低于这个数就说明它更可能是个巧合的字面尾巴，不是一个真称呼。
    private static let minAliasAddressed = 20
    /// 「压倒性最活跃」的倍数。见 ``soleRoleAliases`` 第 3 条。
    private static let aliasDominance = 3
    /// 长的那截至少要自己出现过这么多次，才有资格当被并过去的目标。
    private static let minFragmentMentions = 20
    /// 短名独立出现次数与长名出现次数的比例上限（1/20）。见 ``fragmentAliases`` 第 2 条。
    private static let fragmentDominance = 20
    /// 短名独立出现次数的绝对上限。比例之外还卡这一条，是因为「独立出现过二三十次」的串
    /// 在书里就是被当名字在用，那不是残渣。见 ``fragmentAliases`` 第 2 条。
    private static let maxFragmentStandalone = 10

    private func url(bookID: UUID) -> URL {
        ReaderCache.bookAnalysisDirectory(bookID).appendingPathComponent("roster.json")
    }

    private func read(bookID: UUID) -> Snapshot? {
        guard let data = try? Data(contentsOf: url(bookID: bookID)),
              let written = try? JSONDecoder().decode(Snapshot.self, from: data),
              written.scheme == Self.scheme
        else { return nil }
        return written
    }

    private func write(bookID: UUID, snapshot: Snapshot) {
        let directory = ReaderCache.bookAnalysisDirectory(bookID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url(bookID: bookID), options: .atomic)
    }
}
