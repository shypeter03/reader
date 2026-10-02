//
//  CharacterAnalysis.swift
//  Reader
//
//  一本书的人物分析：书里有哪些人在说话、每个人是男是女。
//
//  为什么要有这一份：声音只按「章内 Character 的性别」选，而正则标注填不出性别
//  （一律 .unknown），于是全书每一个有名有姓的人都落在同一把无名男声上——两个人
//  对话听不出谁是谁。更糟的是这套口径按章各算，同一个人换一章就可能换一把嗓。
//  性别其实正文里写得很明白（他/她、少年/姑娘、王婶/李哥），所以这里用**纯规则**
//  把整本书扫一遍：不跑模型、不占 GPU，也不受章节顺序影响。
//
//  线索只有三类，全是「这个人 + 这一句」级别的局部证据，不做跨句指代消解：
//  ① 名字自带的称谓尾巴（王婶、李哥、张公子）——最强，3 票；
//  ② **紧贴**这个名字的性别名词（「少年韩立」「那姑娘苏晴」「韩立的妻子」）——2 票；
//  ③ 站在名字**后面主语位置**的 他/她（中间只许逗号、停顿和「了着过」）——1 票。
//  两处刻意不收：名字后面直接是「的」（「韩立的母亲来了，她想……」里的她不是韩立）；
//  引号里的内容整段不看（人物台词里的「他」说的是别人，不是说话人自己）。
//  整句只提到一个人也算不上证据：「他看着韩立」里的他另有人。所以 ③ 只认名字**之后**的代词。
//  ② ③ 都不许跨过动词：「宁毅看着那姑娘」「苏檀儿望着他」里的姑娘/他都是另一个人。
//  旧版就错在这里——② 看同句别处的性别词把男主投成女的（赘婿：男 139 / 女 175），
//  ③ 往后看 40 字把宾语代词算给主语（同书苏檀儿 男 50 / 女 47，女主也成了男的）。
//
//  投不满 2 票的判 unknown——宁可继续用默认嗓，也不要凭一句孤证把一个人整个换掉性别。
//

import Foundation

// MARK: - 说话人提取（标注与人物分析共用同一口径）

/// 「这句是谁说的」唯一的提取口径。
///
/// 正则标注（``FastChapterAnalyzer``）和书级人物分析都要认名字，两边各写一份的话，
/// 同一个人在档案里就成两个人、两句两个嗓——所以这份口径只许这一处有。
///
/// 为什么不是正则：提示语的形态是「[赘词]*[名字][状语]*[动词]：」，两头都得剥。
/// 一条 `[^，。！？\s]{1,10}` 的贪婪捕获会把「赵玖沉声道」「他认真说道」「韩立又说道」
/// 整串当名字，于是同一个人换个状语就换一把嗓；而「道」字族（沉声道/苦笑道/单一个「道」）
/// 根本不在旧表里，那些台词被当旁白念掉了——真机日志里绍宋 443 章只认出 58 个说话人，
/// 定出性别的 6 个全是「认真」「然后」这种状语，就是这两条凑出来的。逐字符扫一遍
/// 反而更好剥，也不用养十条 pattern。
enum DialogueAttribution {

    /// 提取口径的版本。改了下面任何一张表都要 +1：已经落库的句子存的是按旧表算出来的
    /// `speaker`/`characterName`，光改代码它们不会自己变（见 ``Chapter/annotationVersion``）。
    ///
    /// 2：加了 ``surnameHeads`` 这道闸门——「开始」「低头」「淡然」这类剥不干净的状语
    /// 从此进不了名字这一列，老章节里那些脏说话人要重算一遍。
    ///
    /// 3：锚点从「只有冒号」扩到冒号 + 引号（「李频笑道，“…”」这种逗号收尾的提示语以前
    /// 整个丢掉），并允许回看分句开头的主语；名字中间带虚词的串（「苏檀儿的」「大概」）
    /// 一并拒收。老章节里那些「认成旁白」的台词要重新认一遍说话人——只有声音真的变了
    /// 的那几句才重录。
    ///
    /// 4：严格口径认出的串**在档案里查不到**时（「方才低头」「马车之上」这类没剥干净的
    /// 动作片段），改用同句里档案已有的人名——两处口径缝成一个。同批：说明文式的冒号
    /// （「解题步骤如下：」）不再回看分句主语，姓表补上漏掉的常用姓（岳薛柳元尹穆雷段纪
    /// 舒尚单岑凌滕焦闵）和群体头「众」。老章节里那些认错的说话人要重算一遍。
    ///
    /// 5：①``relationTitles`` 补了官称（学士/太尉/伯爵/相公…），「小林学士」从此并到「小林」，
    /// 不再是两个人两把嗓；②``validPersonName`` 加了一条「名字里只能有汉字」，真机日志里
    /// 「大（上白」那种跨过括号的串从此不当人；③``CharacterAnalysis/femaleTitles`` 补了
    /// 「后/贵妃/帝姬/娘子」等称谓——绍宋 437 章判出 52 个性别里女的是 0 个。
    /// 这三条都改**谁算名字**，已落库的说话人要重算一遍。
    ///
    /// 6：①``CharacterAnalysis/untailGenderTitle`` 把称谓后面粘的那一截状语切掉（「郑太后身」
    /// 「吴贵妃面」以前切不动，书里的女角因此一句台词都没落到自己嗓上——绍宋 437 章判出 57 人
    /// 里女只有 1 个）；②段内承前（``carriedSpeaker``）：这句台词自己认不出人时借同段上一句的，
    /// 只在引号配对干净的书上开。绍宋实测这类句子有 1758 句（8.6%）。
    /// 两条都改**这句是谁说的**，已落库的句子要重算一遍。
    ///
    /// 7：给「这句是谁说的」加了最前面那道闸门——``speaksInThisSentence``。句子里有引号
    /// 不等于有人在说话：叙述里嵌一段引用（把排版设为“无”、那支‘乞活军’、那些“同龄人”为伍）
    /// 以前一路走到查声，认不出人换一把无名嗓、认错人把整段叙述交给那个角色念。真书实测
    /// 这类句子绍宋 57 句、赘婿 108 句、庆余年 42 句，其中「认出人名、整句交给角色念」的
    /// 26/36/11 句就是最刺耳的那种「旁白换人」。段内承前同受此闸门管（借据在上一句那边，
    /// 只拦上半道会放过「叙述里嵌引用 + 前一句刚好有人说话」）。老章节要按新口径重认一遍。
    /// 8：闸门再补**第 0 条（拦）**——引号里那一截既短又不以句末标点收尾、句子中间还
    /// 没有冒号，那就是叙述里点了个词（一声“停手”、‘忽悠’、‘梦醒’石雕），没人开口。
    /// 上面那五条判据看的都是引号**外面**贴着什么，而这一类外面偏偏就有动词（喊住、
    /// 问了句），一条都拦不住。六本真书实测：切掉的句子十句里七句本来就归旁白，
    /// 剩下的是「嗯，」「善，」这种单字应答——它们原先是把**整段叙述**交给某个角色念。
    /// 同一条改「这句是谁说的」，老章节再重认一遍。
    /// 9：认出来的串**先跟档案对一遍再落库**（``personName(in:knownNames:)``，档案之外的
    /// 那一截由 ``CharacterRoster/fold(_:folds:)`` 按全书出场次数折）。以前对得上
    /// 也照原样存，于是句子上挂的是「韩世忠骤」「赵玖恍然」这种被提示语多吃了一个字的串，
    /// 而档案里是「韩世忠」「赵玖」——查声靠 ``CharacterRoster`` 的前缀折叠还归同一把嗓，
    /// 可这个人的「说过几次话」被自己的残渣分掉了，入档闸门（说≥2、被称呼≥1）反倒过不去，
    /// 台词便整句退回旁白嗓。改的是**存下来的说话人是谁**，老章节重认一遍。
    /// 10：两条一起改的是**档案里有谁**，提取口径没动（四个字以上的串照旧吐出来）：
    /// ①``CharacterAnalysis/foldResidues`` 新增形状并档——四个字的串既不是复姓打头、
    /// 收尾也不是称谓（``explainableLongName``），那它是「姓+名+状语」（「杨毅焦急」），
    /// 不许单独立档，它的「说过话／被称呼／出场」并给同句里那个真名。以前这种脏串各占
    /// 一条档案、各钉一把嗓，同一段里真名与脏串交替念——用户报的「上一句一个声音，
    /// 下一句另一个声音」。配角出场次数不够 20 时按出场次数的并档折不动，所以这一刀
    /// 不能只靠 ``CharacterRoster/prefixFolds``。
    /// ②``countAddressed`` 收窄称呼证据——「盯着王林愣了一下」从前同时给「王林」和
    /// 「王林愣」记一笔「被人当人称呼过」，于是三字残渣也进得了档案（说≥2 且被称呼≥1），
    /// 跟真名各钉一把嗓：同一个人的台词一句男声、一句旁白。
    /// 档案池变了，``personName(in:knownNames:)`` 那条放宽认出来的说话人跟着变，老章节重认一遍。
    static let annotationVersion = 10

    static let minNameLength = 2
    static let maxNameLength = 4

    /// 提示动词。冒号前那段（或引号后那段）必须以这些字收尾才算提示语。
    private static let speechVerbs: Set<String.Element> = [
        "道", "说", "问", "答", "喊", "叫", "喝", "骂", "吼", "讲",
    ]

    /// 名字**后面**、动词**前面**的方式状语与衔接词。从尾部反复剥，剥到不中为止。
    /// 长的写在前头：「不紧不慢」要整块剥，不能被「慢」抢先把尾巴切一半。
    private static let mannerTails: [String] = [
        "不紧不慢", "不急不缓", "阴阳怪气", "慢条斯理", "没好气", "有气无力", "一本正经", "不慌不忙",
        "头也不抬", "看也不看", "笑了笑", "苦笑", "冷笑", "干笑", "假笑", "大笑", "狂笑", "娇笑", "轻笑", "憨笑",
        "沉声", "低声", "高声", "轻声", "大声", "细声", "柔声", "厉声", "扬声", "喃喃", "咕哝",
        "点头", "摇头", "皱眉", "撇嘴", "摊手", "摆手", "招手", "挠头", "挑眉", "瞪眼", "叹气", "叹息",
        "开口", "接着", "接", "补充", "解释", "提醒", "缓缓", "微微", "沉沉", "淡淡", "幽幽", "冷冷",
        "悠悠", "讪讪", "哈哈", "呵呵", "嘻嘻", "嘿", "笑",
        "认真", "继续", "突然", "忽然", "立刻", "马上", "再次", "又", "也", "还", "就", "便", "才", "都", "只",
        "直接", "然后", "却", "竟", "于是", "索性", "干脆", "顺手", "随口", "顺口", "不由", "不禁",
        "说", "问", "答", "喊", "叫", "吼", "骂", "喝", "讲", "了", "着", "过",
    ]

    /// 名字**前面**的赘词：代词、时间词、承接词、语气副词。也只从开头整词剥。
    /// 「众人」「大家」不在此列：它们真会说话，得留成一个说话人（全书同一把嗓）。
    ///
    /// 后面那批「大概/也许/似乎……」是新加的：分句主语那条形状（③④）会把分句开头的
    /// 语气副词整个当名字收下，实测赘婿的档案里就混进了「大概」（提到 154 次）。
    private static let leadingFillers: [String] = [
        "只听见", "只见", "但见", "看着", "望着", "听到", "此时", "这时", "那时", "当下",
        "随后", "旋即", "紧接着", "紧跟着", "跟着", "旁边", "对面", "身后", "前头", "那里", "这儿", "那儿",
        "他们", "她们", "他", "她", "它", "您", "我", "你", "咱", "本人",
        "又", "也", "就", "便", "才", "还", "都", "于是", "然后", "只是", "可是", "但是", "不过", "还是",
        "大概", "大约", "也许", "或许", "可能", "显然", "当然", "居然", "竟然", "似乎", "好像", "仿佛",
        "反正", "究竟", "到底", "幸好", "幸亏", "原来", "其实", "向来", "本来", "同样", "尤其",
    ]

    /// 跟在名字后面的称呼。它们不指明性别（不进 ``CharacterAnalysis/titleSignal`` 的计分），
    /// 只用来认出「名字 + 称呼」这种写法：「韩立师兄」说的就是韩立。
    ///
    /// 后半批是**官称**，绍宋、盘龙实测补上的：同一张脸在书里既有叫「小林」的又有叫
    /// 「小林学士」的，档案里就成了两个人、两把嗓——正是需求里禁止的那种错。这一张表是
    /// 闭口集合（官称就那些个），所以补全比逐本试错便宜。
    ///
    /// 注意它管不到「赵官家」这一类：称呼前面只有一个姓（赵），砍到底就剩一个字，
    /// ``stem`` 那条「砍完必须还剩 2 字」的护栏会把它拦下来，于是它仍是档案里的另一个人。
    /// 姓 + 独指称呼到底指谁（赵官家＝赵玖），是**书外的知识**，局部规则拿不到。
    private static let relationTitles = [
        "师兄", "师姐", "师弟", "师妹", "师父", "师傅", "师叔", "道长", "队长", "团长", "班长",
        "掌柜", "老板", "大人", "兄台",
        // 宋元话本里那一套官称与爵称
        "学士", "相公", "太尉", "通判", "舍人", "中丞", "侍郎", "尚书", "丞相", "参政", "枢密",
        "节度", "总管", "提辖", "教头", "统制", "员外", "太守", "县令", "将军", "伯爵", "侯爵",
        "公爵", "王爷", "郡王", "国公", "夫子",
    ]

    private static let colonCharacters: Set<String.Element> = ["：", ":"]
    private static let quoteOpeners: Set<String.Element> = ["\u{201C}", "\u{2018}", "「", "『"]
    private static let quoteClosers: Set<String.Element> = ["\u{201D}", "\u{2019}", "」", "』"]
    /// 开引号 → **同一种类**的闭引号。中文用“”包台词、‘’包台词里再嵌的引用，
    /// 混着找闭引号会把「“这件‘梦醒’石雕，你也不想看…」读成一段五个字的短引用
    /// （盘龙实测），那是真台词。
    private static let quoteFamilies: [String.Element: String.Element] = [
        "\u{201C}": "\u{201D}", "\u{2018}": "\u{2019}", "「": "」", "『": "』",
    ]
    /// 提示语串不许跨过这些东西：跨过去就不是一个连续的主语了。
    private static let runBreaks: Set<String.Element> = [
        "，", "。", "！", "？", "；", "：", "、", "…", " ", "\u{3000}", "\n", "\t",
        "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "「", "」", "『", "』", "\"", "'",
    ]
    /// 形二（名字跟在引号后面）的那一段，必须止于一句话的末尾。
    private static let attributionEnds: Set<String.Element> = [
        "。", "！", "？", "…", "，", "\u{201D}", "」", "』", "\n",
    ]

    /// 「这一句到底有没有人开口」用得到的表。和 ``speechVerbs`` 分开写：那张是「提示语串
    /// 必须以这些字收尾」，用来**抽名字**，所以只能收最正式的几个字；这张用来**判开口**，
    /// 宁可宽一点——「笑道」「叹了口气」「应道」「嘶」都算有人在说话，哪怕抽不出名字。
    /// 两个用途的容错方向相反，合成一张表就会互相拖累。
    private static let utteranceAnchors: Set<String.Element> = [
        "说", "道", "问", "答", "喊", "叫", "吼", "喝", "骂", "念", "讲", "应", "嚷", "笑", "叹", "嘶",
    ]
    private static let sentenceTerminals: Set<String.Element> = ["。", "！", "？", "…"]
    /// 从引号往前（或往后）回看时跳过的软字符。**冒号与句末标点不在这里**——它们各自
    /// 是一条独立的判据，被跳过去就等于把判据抹了。
    private static let utteranceSkips: Set<String.Element> = [
        "了", "着", "地", "，", "、", " ", "\u{3000}",
    ]

    /// 这一句是不是**真的一次开口**：「这句是谁说的」这条链最前面的一道闸门。
    ///
    /// 为什么非要有这道闸门：叙述里带引号的东西太多了——心里想的那句话、引用的字、
    /// 术语、书名、强调（把排版设为“无”、那支‘乞活军’、那些“同龄人”为伍）。旧口径
    /// 「句子里有引号就算台词」把它们一律当台词，于是认不出人时换一把无名嗓、认错人时
    /// 整句叙述交给某个角色念。听感正是需求里禁止的那种：上一句旁白 A、下一句旁白 B。
    ///
    /// 判据全是**闭口的结构**（任一满足即算开口）：
    /// 0. 先拦一道：引号里那截既短（≤6 字）又不以句末标点收尾，整句中间还没有冒号
    ///    ——那是叙述里点了个词，不是有人开口（见 ``quotedRunsAreOnlyTerms``）；
    /// 1. 引号就是这句的开头——「“禀大家。”那壮汉手足无措」，提示语在后面；
    /// 2. 引号前面是冒号——「他站了起来：“如果能再来一次…”」；
    /// 3. 引号前面是句末标点——作者把台词单独成句；
    /// 4. 引号前面贴着提示动词（跳过 了/着/地/，）——「…哭了起来：“爸爸…”」；
    ///    闭合引号后面紧贴提示动词也算（「“……”他问道。」）；
    /// 5. 有一对引号**以句末标点收尾**——「他转过头，目光严厉，“你以为自己是什么？”」。
    ///
    /// 第 5 条单独说：中文网文里「叙述小句 + 逗号 + 整句台词」极常见，而提示动词在更前面
    /// 的分句里（甚至没有），前四条一条都不贴，可它确实是开口——「小婵小脸满是疑惑，
    /// “趴在地上，就是这样把自己推起来……”」。反过来，内嵌的术语/引用在引号里不带任何
    /// 句末标点（“扎”“妻子”‘历史名人’“明月几时有”）。这条界线实测是三本书里分得最开的
    /// 一条：赘婿被误当台词的旁白从 177 句降到 108 句，而「“准吗？”」「“你怎么想？”」
    /// 这类真台词一句没丢。代价是引号里带标点的**引用**（“富与贵，是人之所欲也……”）
    /// 会漏过来，那类句子本来也读得像说话，不换人就不算错。
    static func speaksInThisSentence(_ text: String) -> Bool {
        let letters = Array(text)
        guard let quote = letters.firstIndex(where: { quoteOpeners.contains($0) }) else { return false }
        // 第 0 条是**拦**：引号里那一截根本不是「一句话」，这句就没人开口（见上面 8 的说明）。
        if quotedRunsAreOnlyTerms(letters) { return false }
        var i = quote - 1
        while i >= 0, utteranceSkips.contains(letters[i]) { i -= 1 }
        if i < 0 { return true }
        if colonCharacters.contains(letters[i]) { return true }
        if sentenceTerminals.contains(letters[i]) { return true }
        if utteranceAnchors.contains(letters[i]) { return true }
        if let close = letters.firstIndex(where: { quoteClosers.contains($0) }), close + 1 < letters.count {
            var j = close + 1
            while j < letters.count, utteranceSkips.contains(letters[j]) { j += 1 }
            if j < letters.count, utteranceAnchors.contains(letters[j]) { return true }
        }
        var opened = false
        for position in letters.indices {
            let character = letters[position]
            if quoteOpeners.contains(character) { opened = true }
            guard quoteClosers.contains(character), opened else { continue }
            var tail = position - 1
            while tail >= 0, quoteClosers.contains(letters[tail]) { tail -= 1 }
            if tail >= 0, sentenceTerminals.contains(letters[tail]) { return true }
            opened = false
        }
        return false
    }

    /// 每一段引号都是「又短（≤6 字）、又不以句末标点收尾」→ 这句里没人把一句话说完，
    /// 引号只是叙述里点的一个词：「却被敖乙一声“停手”喊住」「说‘忽悠’也不太准确」
    /// 「叫“弱国无外交”」「‘梦醒’石雕！」「“哈哈哈，”赵公明大笑几声」。
    ///
    /// 为什么放在最前面当第 0 条：其余五条判据看的全是引号**外面**贴着什么，而这一类
    /// 外面偏偏就有动词（喊住、问了句、大笑），一条都拦不住，于是整段叙述被交给那个
    /// 被点名的角色念——正是「旁白这一句 A、下一句 B」。
    ///
    /// 三处护栏，都是为了**别切到真台词**（上一轮的教训：结构判据判错方向一次就误杀
    /// 九成台词）：①引号按种类配对，嵌套的‘’不会被当成“”的收尾；②找不到同类闭引号就
    /// 量到句尾——断句常把台词切在半截（「“放心，”他正色道：“……”」），后半截才是真话；
    /// ③句中出现冒号一律放行，那是「道：“……”」的排版，短也算开口。
    /// 长度量的是**引号里那一截**，不看句子长短：一句「X 道：“今天天色不好，不如留下吃饭。」
    /// 只因为没收到闭引号就算开口，而「他把“稳”字挂在嘴边」永远只算一个词。
    private static func quotedRunsAreOnlyTerms(_ letters: [String.Element]) -> Bool {
        if letters.contains(where: { colonCharacters.contains($0) }) { return false }
        var sawQuote = false
        for position in letters.indices {
            guard let closer = quoteFamilies[letters[position]] else { continue }
            sawQuote = true
            var end = letters.count
            var scan = position + 1
            while scan < letters.count {
                if letters[scan] == closer { end = scan; break }
                scan += 1
            }
            if end - position - 1 > 6 { return false }
            let upper = max(end, position + 1)
            if letters[(position + 1)..<upper].contains(where: { sentenceTerminals.contains($0) }) {
                return false
            }
        }
        return sawQuote
    }

    /// 提示语原始串（**带**动词，还没剥赘词）。取第一个能剥出合法人名的位置。
    ///
    /// 锚点是**引号和冒号**，不是只有冒号——真书里大量提示语用逗号收尾（「李频笑道，
    /// “……”」），实测赘婿 60 章里这种写法占未归属句的一大块，只盯冒号等于把它们全放弃。
    ///
    /// 四种形态：①「赵玖沉声道：“…”」②「“…”赵玖说道。」——冒号/引号挨着提示动词；
    /// ③「宁毅也只得笑笑：“…”」④「“哦。”宁毅点点头，随后又笑起来，“……”」——
    /// **名字在分句开头**，中间没有提示动词，只有逗号。③④ 是量出来补上的：中文的主语
    /// 在分句头上，而 ①② 那种「贴着动词剥」的口径结构上够不到逗号那头的名字。
    static func speakerName(in text: String) -> String? {
        let characters = Array(text)
        var position = 0
        while position < characters.count {
            let current = characters[position]
            var run: String?
            if colonCharacters.contains(current) {
                // 冒号后面跟着引号才算「有人说了话」。说明文的冒号（「解题步骤如下：」）
                // 没有提示动词也没有台词，回看分句开头就会捞出「解题步骤」这么个说话人。
                run = speakerBefore(characters, end: position, allowsClauseHead: startsQuote(characters, after: position))
            } else if quoteOpeners.contains(current) {
                run = speakerBefore(characters, end: position, allowsClauseHead: true)
            } else if quoteClosers.contains(current) {
                run = speakerAfter(characters, start: position + 1)
            }
            // 剥不出人名的段就地丢掉，接着看下一段：一句里可能有好几个引号。
            if let run, validPersonName(canonicalName(run)) != nil { return run }
            position += 1
        }
        return nil
    }

    /// 这个位置之后（跳过空格）的第一个字是不是开引号。
    private static func startsQuote(_ characters: [String.Element], after position: Int) -> Bool {
        var index = position + 1
        while index < characters.count, characters[index] == " " { index += 1 }
        return index < characters.count && quoteOpeners.contains(characters[index])
    }

    /// 从 `end`（不含）往回找：先看紧贴的那一段是不是提示语，不是就逐分句往回看开头。
    /// `allowsClauseHead` 关掉回看（说明文式冒号），只留「贴着动词」那一条最硬的证据。
    private static func speakerBefore(
        _ characters: [String.Element],
        end: Int,
        allowsClauseHead: Bool
    ) -> String? {
        // 提示语和引号之间可以隔一个分隔符（「李频笑道，“…”」的逗号），句号不行。
        var anchor = end
        var skipped = 0
        while anchor > 0, softBreaks.contains(characters[anchor - 1]), skipped < 2 {
            anchor -= 1
            skipped += 1
        }
        if let run = runEndingAt(characters, anchor), validPersonName(canonicalName(run)) != nil { return run }
        guard allowsClauseHead else { return nil }
        return clauseHeadRun(characters, end: anchor)
    }

    /// 引号往后找：先看紧贴的提示语（「“…”赵玖说道。」），再看那一段分句的开头（④）。
    private static func speakerAfter(_ characters: [String.Element], start: Int) -> String? {
        if let run = runStartingAfter(characters, start), validPersonName(canonicalName(run)) != nil { return run }
        var from = start
        var skipped = 0
        while from < characters.count, softBreaks.contains(characters[from]), skipped < 2 {
            from += 1
            skipped += 1
        }
        guard from < characters.count else { return nil }
        var to = from
        while to < characters.count, !runBreaks.contains(characters[to]) { to += 1 }
        guard to > from, to - from <= 12 else { return nil }
        return leadingNameRun(Array(characters[from..<to]))
    }

    /// 冒号往前取一段连续非分隔符的串，必须以提示动词收尾。
    private static func runEndingAt(_ characters: [String.Element], _ colon: Int) -> String? {
        var start = colon
        while start > 0, !runBreaks.contains(characters[start - 1]) { start -= 1 }
        guard start < colon, colon - start <= 12, speechVerbs.contains(characters[colon - 1]) else { return nil }
        return String(characters[start..<colon])
    }

    /// 逗号可以跨（「苏檀儿捂着嘴笑了起来，随后道」的主语在前一个分句），
    /// 句号、引号、破折号不行——跨过去就不是同一个主语了。
    private static let clauseHops: Set<String.Element> = ["，", "、", "；"]
    /// 跳得过去的分隔符（提示语和引号之间、引号和后面的主语之间）。句号不在内。
    private static let softBreaks: Set<String.Element> = ["，", "、", "；", "：", "…"]
    /// 最多回看几个分句。再多就可能翻到上一个人说的话上去。
    private static let maxClauseHops = 2

    /// 从 `end`（不含）往回，逐分句取**开头**那 2~4 个字当名字试。
    private static func clauseHeadRun(_ characters: [String.Element], end: Int) -> String? {
        var boundary = end
        var hops = 0
        while hops <= maxClauseHops {
            var start = boundary
            while start > 0, !runBreaks.contains(characters[start - 1]) { start -= 1 }
            if start < boundary, let head = leadingNameRun(Array(characters[start..<boundary])) { return head }
            guard start > 0, clauseHops.contains(characters[start - 1]) else { return nil }
            boundary = start - 1
            hops += 1
        }
        return nil
    }

    /// 分句开头是不是一个名字：从最长试到两字，取第一个成形的。
    /// 多带一个字（「苏檀儿捂」）没关系——档案归并按出场次数把它并回「苏檀儿」，
    /// 查声时也是按前缀查的，两句还是同一把嗓。
    /// 四个字的串（「杨毅焦急」这种「姓+名+两字状语」）也照旧吐出来：这里是**提取**，
    /// 砍在这里会把同句真名一起砍掉（赘婿实测严格口径 455 句→213 句，代价减半还多）。
    /// 脏串进不了档案——``CharacterAnalysis/foldResidues`` 按形状把它并回真名。
    /// 名字后面紧接「的」整段作废：「苏檀儿的丫鬟低声道」说话的是丫鬟。
    private static func leadingNameRun(_ clause: [String.Element]) -> String? {
        let longest = min(maxNameLength, clause.count)
        for length in stride(from: longest, through: minNameLength, by: -1) {
            let prefix = String(clause[0..<length])
            guard validPersonName(canonicalName(prefix)) != nil else { continue }
            if length < clause.count, clause[length] == "的" { return nil }
            return prefix
        }
        return nil
    }

    /// 引号往后取一段，必须以提示动词收尾、且紧跟句末标点或到句尾。
    private static func runStartingAfter(_ characters: [String.Element], _ start: Int) -> String? {
        var end = start
        while end < characters.count, !runBreaks.contains(characters[end]), end - start <= 12 { end += 1 }
        guard end > start, speechVerbs.contains(characters[end - 1]),
              end == characters.count || attributionEnds.contains(characters[end])
        else { return nil }
        return String(characters[start..<end])
    }

    /// 把原始串收拾成能比对的名字：剥尾动词、剥前后赘词、去首尾标点。
    /// 只做裁剪，不做判断——人物档案查表时也走这一步，两边才认得出彼此。
    static func canonicalName(_ raw: String) -> String {
        let edges = CharacterSet(charactersIn: " \n\t\u{201C}\u{201D}\u{2018}\u{2019}「」『』【】（）()《》、。，,.!?！？:：…-—~·")
        var name = raw.trimmingCharacters(in: edges)
        // 动词只剥一个字：「王笑道」这种名字本身收尾带「笑」的，剥成「王」就把人弄丢了，
        // 而「赵玖说道」剩下来那个「说」由赘词表接着处理。
        if let last = name.last, speechVerbs.contains(last) { name = String(name.dropLast()) }
        name = strip(name, words: leadingFillers, at: .head)
        name = strip(name, words: mannerTails, at: .tail)
        return untailGenderTitle(name)
    }

    /// 尾巴上多挂着残渣字、把称谓挤出末位的，把那一截切掉：「吴贵妃面（色）」「郑太后身」「潘妃（贵妃）闻（言）」。
    ///
    /// 为什么必须有这一条：性别称谓是按**结尾**匹配的（``CharacterAnalysis/hasGenderTitle`` 用 hasSuffix），
    /// 而分句头那条形状（③④）会把主语后面第一个字一起吃进来 —— 于是绍宋 437 章里
    /// 「吴贵妃面」「潘贵妃闻」「郑太后身」「赵夫人不」「范秀娘望」各 1 次，全部**带的是真人的台词**，
    /// 却因为尾巴上那一个字不再是「带称谓的人」：入档要过「说过两次话 + 被人称呼过」那道闸门（她们说过一次），
    /// 性别也拿不到称谓那 3 票，结果这一本书里判出 60 个男的、女的是 **1 个**，
    /// 而那几句确确实实是女人说的话全压在男嗓上。
    ///
    /// 只切**切完末尾正好是个称谓**的那些，且串本身已经带称谓就不动 —— 所以幂等，
    /// 且判定完全靠称谓表那几个闭口词，不新增任何开放词表。
    /// 切多了的代价落在「姓 + 称谓 + 一个真名用字」这种写法上（书里极少，实测绍宋只有 潘妃/吴贵妃
    /// 这类同一把嗓的两种写法，切完仍是女声，不换人）。
    private static func untailGenderTitle(_ name: String) -> String {
        guard !CharacterAnalysis.hasGenderTitle(name) else { return name }
        for cut in 1...2 {
            guard name.count - cut >= minNameLength else { break }
            let shorter = String(name.dropLast(cut))
            if CharacterAnalysis.hasGenderTitle(shorter) { return shorter }
        }
        return name
    }

    /// 一个能当名字用的串：2~4 字、不含阿拉伯数字、**首字得是个姓**（或昵称头、复姓）。
    /// 标注落库和档案收录都只认这个口径，否则章里存进「这句话他知道」那种六字串、
    /// 档案里却没有，同一个人就两处两嗓。
    ///
    /// 数字只看 ASCII 与全角那十个：`isNumber` 走的是 Unicode 数字属性，汉字数字
    /// 「九」「玖」（玖是九的大写）也带这个属性——赵玖会被当成脏名整条丢掉。
    /// 真机日志里主角一个没认出来，一半原因是它。
    ///
    /// 姓表这道闸门是治脏名的正招。先前那版走**反面**枚举（状语表越列越长），真书一测
    /// 就废：赘婿 60 章里冒出来的表外脏名有 开始、终于、低头、扭头、随意、淡然、用力地、
    /// 咬牙、乌龟……状语在汉语里是开口的，永远列不完；而**姓是闭口的**（常用姓几百个，
    /// 而状语的第一个字几乎不会撞上一个姓）。所以反过来判：首字不在姓表里就不是名字。
    /// 代价是极罕见姓的人物（随、淡、那、乌）认不出来，退回无名男声——比把「低头」当成
    /// 一个人、让一堆不同人的台词共用一把嗓划算。
    ///
    /// 但首字姓表只管得到**左边界**：「杨毅焦急说道」这一段，姓表认出「杨」打头，
    /// 虚词表看串里没有「的了着」，两道都放行，于是尾巴上那截状语跟着名字一起落库，
    /// 存成「杨毅焦急」这么个不存在的人（用户报的第一条）。右边界只能靠**结构**定
    /// （见 ``explainableLongName``），可它**不许落在提取上**：试过砍在 `validPersonName`
    /// 里，赘婿 60 章严格口径从 455 句掉到 213 句——那些串的真名就在同一句开头，
    /// 整段作废等于连真名一起丢。所以这一刀砍在**并档**上：脏串照样吐出来，
    /// 但它的「说过话／被称呼／出场」全部并给同句那个真名，自己进不了档案。
    static func validPersonName(_ name: String) -> String? {
        let digits = Set("0123456789０１２３４５６７８９")
        guard name.count >= minNameLength, name.count <= maxNameLength,
              !name.contains(where: { digits.contains($0) }),
              !name.contains(where: { functionCharacters.contains($0) }),
              name.allSatisfy({ isNameCharacter($0) }),
              let first = name.first, surnameHeads.contains(first) || hasCompoundSurname(name)
        else { return nil }
        return name
    }

    /// 长到四个字的串得有个**说法**：要么打头是复姓（「司马」「长孙」那一类），
    /// 要么收尾是个称谓（「韩立师兄」「吴贵妃」）。
    ///
    /// 为什么单挑四个字：汉字名字到四个字只有那两类写法，而提示语吃进状语时产出的
    /// 恰恰也是四个字——「杨毅焦急」「赵玖恍然」「宁毅无奈」「陆阿贵连」这种
    /// 「姓+名+两字状语」。三字以下没法这么判（「王林海」是双名，「杨毅急」是残渣，
    /// 字面上同形），那一档只能靠 ``CharacterAnalysis/countAddressed`` 收窄称呼证据来拦。
    /// 状语是开口集合，列不完；姓和称谓是闭口的，列得完——所以判据落在闭口表上。
    /// 用在哪：``CharacterAnalysis/foldResidues`` 的形状并档。代价是「姓+三字名」这种
    /// 极少数写法会被并到自己两字前缀上——听感上只是同一个人少了一把独立的嗓。
    static func explainableLongName(_ name: String) -> Bool {
        hasCompoundSurname(name)
            || CharacterAnalysis.hasGenderTitle(name)
            || relationTitles.contains { name.hasSuffix($0) }
    }

    /// 名字里的字只能是个汉字。真机日志里出现过「大（上白」这种说话人：提示语段跨过了括号，
    /// 于是档案里要是有「大（上白」这么个人，配到的嗓和念「大」的那把根本不相干，
    /// 而首字姓表只看第一个字（大是昵称头），拦不住后面的残渣。
    /// 数字、虚词各有一条专门的表，这一条管剩下的所有非汉字字符（全角标点、字母、空格）。
    private static func isNameCharacter(_ character: String.Element) -> Bool {
        ("\u{4E00}"..."\u{9FFF}").contains(character)
    }

    /// 一个词是不是「能单独用来叫人」的称呼（辈分、官称、性别名词）。
    /// 归并残渣时只有并到这类词上才算数，见 ``CharacterAnalysis/isAddressWord``。
    static func isRelationTitle(_ word: String) -> Bool {
        relationTitles.contains(word)
    }

    /// 名字**中间**绝不会出现这些字。它们一出现就说明这串是「苏檀儿的丫鬟」「他看了看」
    /// 这种没剥干净的短语，而不是人名。首字姓表管的是这串**开头**像不像姓，这一条管它
    /// 里面有没有虚词——两道闸门都在闭口集合上，不像状语表那样永远列不完。
    private static let functionCharacters: Set<String.Element> = [
        "的", "了", "地", "着", "过", "是", "在", "把", "被", "让", "呢", "吗", "吧", "啊", "呀", "哦",
    ]

    /// 复姓只在**整块撞上**时算数。上一版把 上/南/皇/宇/鲜/闾/端/诸/慕/尉 也当单姓收，
    /// 分句主语那条形状（③）一开就漏进「上方」「南方」这种方位词——它们当姓极罕见，
    /// 当状语、方位开头却天天见。
    private static func hasCompoundSurname(_ name: String) -> Bool {
        compoundSurnames.contains { name.hasPrefix($0) }
    }

    /// 「东方」「百里」不进这张表：它们当方位、当数量更常见。
    private static let compoundSurnames = [
        "欧阳", "上官", "夏侯", "诸葛", "司徒", "司马", "独孤", "南宫", "慕容", "长孙",
        "宇文", "令狐", "轩辕", "公孙", "呼延", "完颜", "万俟", "闻人", "钟离", "宗政",
        "皇甫", "尉迟", "鲜于", "闾丘", "端木", "申屠", "仲孙", "太叔", "西门",
    ]

    /// 姓头集合：现代人口最多的那一批 + 百家姓里小说还会用的 + 网文爱用的（楚、夜、君、姬）
    /// + 昵称头（小六、阿福、三爷）。复姓走 ``compoundSurnames``，不在这里。
    ///
    /// 这一份是**筛过**的：凡是「这个字打头、后面接个词就很常见」的都删了
    /// （乌=乌龟、后=后面、相=相信、都=都是、全=全部、公=公开、空=空气、墨=墨绿、
    /// 终=终于、简=简单、连=连忙、别=别人、幸=幸好、怀=怀疑、危=危险、充=充满、
    /// 满=满意、利=利用、越=越来越、于=于是、师=师父、容=容易、甘=甘心），
    /// 因为状语残渣比罕见姓的人物更常出现在提示语里，而错收一个名字的代价是把一堆不同人
    /// 的台词并到同一把嗓上。改这张表等于改提取口径，要同时 +1 ``annotationVersion``
    /// 和 ``CharacterRoster/scheme``。
    ///
    /// 复姓第一个字（上/南/皇/宇/鲜/闾/端/诸/慕/尉）也不在这里，它们在 ``compoundSurnames``
    /// 里整块作数：单个「上」字当姓几乎没有，当「上方」「上面」的开头天天有。
    private static let surnameHeads: Set<String.Element> = [
        // 现代人口最多的那一批
        "王李张刘陈杨黄赵周吴徐孙马朱胡郭何高林罗郑梁谢宋唐许邓冯",
        "韩曹彭曾肖萧田董潘袁蔡蒋余杜叶程魏苏吕丁任卢傅沈钟姜崔谭",
        "廖范汪陆金石姚汤贾夏邹方白孟熊秦邱江侯龙史陶黎贺顾郝龚邵",
        "万钱严覃武戴孔施文牛樊葛邢安齐易乔伍庞聂查池童颜梅鲍解华",
        // 百家姓里还会当名字头出现的
        "甄屈麻路娄殷柯阮季巴弓牧隗车宓蓬郗班仰秋仲伊宫宁仇厉戎祖符景詹束司韶宿屠",
        "庄晏瞿阎茹宦艾鱼慎戈庾暨居衡步耿弘匡国阙殳沃蔚夔隆巩晁敖融冷辛",
        "饶毋沙养鞠须丰巢关蒯游竺权桓",
        // 上一版漏掉的常用姓：岳鹏举、薛蟠、柳青狄、尹熙、穆元念、雷轰、段誉、纪晓芙、
        // 舒展、尚云祥、单雄信、岑参、凌云、焦仲卿、闵子骞。漏一个就等于这个人整本书没有
        // 档案，台词全落无名嗓——姓是闭口集合，补全比逐本真书试错便宜。
        "岳薛柳元尹穆雷段纪舒尚单岑凌滕焦闵",
        // 网文里当姓用惯了的
        "楚夜君姬凤战",
        // 昵称头：「小六」「阿福」「三爷」「老太」都是真会说话的人；「少年」这种没有名字、
        // 只用辈分称呼的人也一样会说话（性别由 ``titleSignal`` 认）。
        "小大阿老二三少",
        // 群体头：「众人」「大家」真会一齐说话，给它们一把公共嗓（用户允许多人共用一把声音）
        "众",
    ].reduce(into: Set<String.Element>()) { set, group in
        set.formUnion(group)
    }

    /// 一句台词的说话人。认不出来返回 nil（那句按旁白念）。
    ///
    /// 第一道闸门是 ``speaksInThisSentence``：**这句根本没有人在说话时，不许给任何人**。
    /// 叙述里嵌一段引用（那支‘乞活军’、那些“同龄人”为伍）以前会一路走到查声，
    /// 认不出人换一把无名嗓、认错人把整段叙述交给某个角色念——那就是「旁白换人」。
    static func personName(in text: String) -> String? {
        guard speaksInThisSentence(text) else { return nil }
        return speakerName(in: text).flatMap { validPersonName(canonicalName($0)) }
    }

    /// 严格口径认不出名字时，退一步取「这句里出现过、档案里已有的人名」，同句多人取句首。
    ///
    /// 反过来也补一刀：严格口径**认出了串、但那串在档案里查不到**时，同句的档案人名更可信。
    /// 严格串常常是没剥干净的动作片段（「方才低头」「马车之上」「秦管事只」），档案里根本
    /// 没有这个人，查声只能退回无名嗓；而同一句的叙述里往往就挂着真名（「聂云竹……方才低头
    /// 笑道：“……”」）。这一刀把两处口径缝成一个：凡是落到档案之外的名字，先看档案里有没有
    /// 人，实在没有才留着原串——留着不为已甚，那个人第一次出场时档案确实还没有他。
    ///
    /// 为什么要退这一步：提示语段**不许跨逗号**（跨过去就会把「他认真说道」整串当名字），
    /// 而真书的写法偏偏是「宁毅看着苏檀儿，低声道：“……”」——名字在逗号那头，严格口径
    /// 结构上就够不着。赘婿第 101~160 章实测：严格口径认出 22.0%，放宽之后 23.7%；
    /// 换成「叙述里点了人名的那些句子」当分母（557 句），认出 88.2%，剩下的是真没有线索
    /// （「“知道了……”苏檀儿做出微微有些糗的表情。」这种名字后面紧跟「的」的写法）。
    ///
    /// 三道护栏，缺一不可：
    /// - 候选只能来自**人物档案**（``CharacterRoster``），不是从字面现编：档案已经过首字姓表
    ///   与两次出场的闸门，「扭头」「淡然」不会被当成人——这是这条规则成立的前提。
    /// - 引号里的内容整段不看：「“我叫宁毅。”她轻声道。」说的是她，不是宁毅。
    /// - 名字后面紧接「的」不算：「宁毅的妻子低声道」说话的是妻子。
    static func personName(in text: String, knownNames: Set<String>) -> String? {
        // 同一条闸门，而且必须在这里也拦一遍：下半段（同句档案人名）走的是 `poolName`，
        // 不经 `personName(in:)`，只在上半道拦等于放过了「叙述里点了人名 + 一段引用」这一大类。
        guard speaksInThisSentence(text) else { return nil }
        if let strict = personName(in: text) {
            // 档案里已经有这个人，就落到**档案里那一串**上。查声那边本来就会按前缀把
            // 「韩世忠骤」折到「韩世忠」（``CharacterRoster/person``），名字却照原样存着——
            // 同一个人的证据被自己的残渣分成几条，「说过几次话」每条都不够入档闸门。
            if let folded = folded(name: strict, pool: knownNames) { return folded }
            guard !knownNames.isEmpty else { return strict }
            return poolName(in: text, knownNames: knownNames) ?? strict
        }
        return poolName(in: text, knownNames: knownNames)
    }

    /// 这串在候选池里对得上谁：原串、剥称呼的词干、更短的前缀、更长的后缀都算。
    /// 与 ``CharacterRoster/person(bookID:name:)`` 的折叠方向保持一致，否则提取侧认为
    /// 「档案里有这个人」而查声查不到，同一个人就两句两嗓。
    ///
    /// 标注落库前也用它折一次（``CharacterRoster/renamePool(bookID:)`` 给的那个大池子）：
    /// 书刚开始扫、真名还没攒够「说过两次话」的时候，档案里没有韩世忠，可句子上已经挂着
    /// 「韩世忠骤」了——那正是「把单词解析为人物」被看见的地方。
    static func folded(name: String, pool: Set<String>) -> String? {
        if pool.contains(name) { return name }
        let stem = stem(name)
        if pool.contains(stem) { return stem }
        // 前缀、后缀都只试这串自己的几截（≤3 截），不做「拿整池名字来比」的 O(池子) 扫描：
        // 每一句都要查一次，整池扫描的成本会在迁移那种一次性遍历里放大成几百毫秒。
        for length in stride(from: name.count - 1, through: minNameLength, by: -1)
        where pool.contains(String(name.prefix(length))) {
            return String(name.prefix(length))
        }
        for start in 0..<name.count {
            let suffix = String(name.dropFirst(start))
            if suffix.count >= minNameLength, pool.contains(suffix) { return suffix }
        }
        return nil
    }

    private static func poolName(in text: String, knownNames: Set<String>) -> String? {
        guard !knownNames.isEmpty else { return nil }
        // 先按首字筛：档案池上百个名字，每个都扫一遍整句是几百次字符串查找，而句子里
        // 没有这个首字就必然没有这个名字。整章迁移实测吃在这上面（300 句 128ms）。
        let heads = Set(text)
        let candidates = knownNames.filter { heads.contains($0.first!) }
        guard !candidates.isEmpty else { return nil }
        let masked = Array(maskDialogue(text))
        // 叙述部分里没有提示动词，就只是「引号 + 一段提到某人的叙述」，那种句子不该猜。
        guard masked.contains(where: { speechVerbs.contains($0) }) else { return nil }
        var best: (position: Int, name: String)?
        for name in candidates {
            guard let position = firstBindingPosition(masked, name: name) else { continue }
            if let current = best, current.position < position { continue }
            // 同一起点取更长的名字：档案里同时有「宁毅」和「宁毅之」时，短的那个是残渣。
            if let current = best, current.position == position, current.name.count >= name.count { continue }
            best = (position, name)
        }
        return best?.name
    }

    /// 这个名字在句里第一次「当主语」的位置：紧跟着「的」的那些出现都不算。
    private static func firstBindingPosition(
        _ characters: [String.Element],
        name: String
    ) -> Int? {
        let letters = Array(name)
        guard !letters.isEmpty, letters.count <= characters.count else { return nil }
        var index = 0
        while index + letters.count <= characters.count {
            if Array(characters[index..<(index + letters.count)]) == letters,
               index + letters.count == characters.count || characters[index + letters.count] != "的" {
                return index
            }
            index += 1
        }
        return nil
    }

    /// 引号里的话整段抹成空格（长度不变，下标还对得上）。
    /// 提取和性别投票共用这一份：两边对「哪一段是台词」口径不同的话，同句两个人名就会
    /// 在标注里是一个说话人、在档案投票里又是另一个人。
    static func maskDialogue(_ text: String) -> String {
        var output = ""
        var inside = false
        for character in text {
            switch character {
            case "\u{201C}", "\u{2018}", "「", "『": inside = true
            case "\u{201D}", "\u{2019}", "」", "』": inside = false
            default: break
            }
            output.append(inside ? " " : String(character))
        }
        return output
    }

    private enum StripEdge { case head, tail }

    /// 整词反复剥离。允许把整串吃光——吃光就是「这句认不出是谁说的」，
    /// 比硬留一个「认真」当名字好：那种脏名会白占一把声音，还会被同句的性别词判错性别。
    private static func strip(_ name: String, words: [String], at edge: StripEdge) -> String {
        var current = name
        var matched = true
        while matched, !current.isEmpty {
            matched = false
            for word in words where word.count <= current.count {
                let hits = edge == .head ? current.hasPrefix(word) : current.hasSuffix(word)
                guard hits else { continue }
                current = edge == .head
                    ? String(current.dropFirst(word.count))
                    : String(current.dropLast(word.count))
                matched = true
                break
            }
        }
        return current
    }

    /// 名字 + 称呼（「韩立师兄」）砍到名字。只认 ``relationTitles`` 里有的称谓，
    /// 而且砍完必须还剩 2 字以上：「王叔」砍到底只剩个姓，那种名字要留着（性别就在称谓里）。
    static func stem(_ name: String) -> String {
        var current = name
        while current.count > minNameLength,
              let cut = relationTitles.first(where: { current.hasSuffix($0) }).flatMap({
                current.count > $0.count ? String(current.dropLast($0.count)) : nil
              }),
              cut.count >= minNameLength {
            current = cut
        }
        return current
    }
}

// MARK: - 分析

enum CharacterAnalysis {

    struct Person: Hashable {
        let name: String
        let gender: Gender
        let maleVotes: Int
        let femaleVotes: Int
        let mentions: Int
        /// 这一批正文里被认作说话人的次数。**这里只报数，不判够不够**：
        /// 「说过两次话」那道闸门必须按**整本书**累计，而扫描是一批一批喂进来的
        /// （设备上是 7 章一轮）。按批次判的话，每章说一次话的人轮轮都不达标，
        /// 整本书几百句台词就全压在无名嗓上——绍宋实测 7 章一轮入档 0 人、整本扫 111 人。
        let attestations: Int
        /// 这一批里在「人称宾语」位置上被叫到过的次数（看见/听见/叫/对…+ 这串）。
        /// 和 ``attestations`` 一起累计，是档案收不收这个人的第二条闸门。
        let addressed: Int

        /// 两个闸门字段有默认值：只关心「谁说了什么」的旧调用（探针里那批手写的名字）
        /// 不必造假数，代价是它们永远过不了入档闸门——探针要测闸门时自己填上。
        init(
            name: String,
            gender: Gender,
            maleVotes: Int,
            femaleVotes: Int,
            mentions: Int,
            attestations: Int = 0,
            addressed: Int = 0
        ) {
            self.name = name
            self.gender = gender
            self.maleVotes = maleVotes
            self.femaleVotes = femaleVotes
            self.mentions = mentions
            self.attestations = attestations
            self.addressed = addressed
        }
    }

    /// 一遍扫完一本书：`chapterTexts` 是按章给出的句子文本（章序只影响日志）。
    static func analyze(chapterTexts: [[String]]) -> [Person] {
        let evidence = candidateNames(from: chapterTexts)
        var votes: [String: (male: Int, female: Int, mentions: Int)] = Dictionary(
            uniqueKeysWithValues: evidence.keys.map { ($0, (0, 0, 0)) }
        )
        guard !votes.isEmpty else { return [] }

        // ① 名字自带的称谓：一次算完，不必逐句再看
        for name in votes.keys {
            guard let signal = titleSignal(name) else { continue }
            add(name, gender: signal.gender, weight: signal.weight, to: &votes)
        }

        // 本模块自己有一个 Character（人物模型），所以这里一律写 String.Element 指字符。
        let byFirstCharacter = Dictionary(grouping: Array(votes.keys), by: { $0.first! })

        var previousNarration: String?
        for text in chapterTexts.joined() {
            let narration = DialogueAttribution.maskDialogue(text)
            let present = namesPresent(narration, byFirstCharacter: byFirstCharacter)

            // ④ 承前主语：本句一个名字都没有、开头就是 他/她，而**上一句**里只有一个名字、
            // 还正做着主语。这一条是给「苏仲堪摇了摇头。他叹了口气。」这种形状准备的——
            // 一句一句喂进来时，③ 永远看不见跨了句号的那个代词，赘婿实测出场 70 次的
            // 苏仲堪、58 次的李频一张票都捞不着，整本书的配角全退回无名嗓。
            // 只回看一句：回看两句就会撞上「他」其实指中间那句里那个没名字的人。
            if present.isEmpty, let pronoun = leadingPronoun(narration),
               let subject = carriedSubject(previousNarration, byFirstCharacter: byFirstCharacter) {
                add(subject, gender: pronoun == "他" ? .male : .female, weight: 1, to: &votes)
            }
            previousNarration = narration

            guard !present.isEmpty else { continue }
            for name in present { countMention(name, to: &votes) }

            // ② 只认和名字**绑在一起**的性别词
            for name in present {
                guard let gender = boundGender(narration, name: name) else { continue }
                add(name, gender: gender, weight: 2, to: &votes)
            }

            // ③ 名字之后紧跟的 他/她
            for name in present {
                guard let pronoun = pronounAfter(
                    narration,
                    name: name,
                    otherNames: present.filter { $0 != name }
                ) else { continue }
                add(name, gender: pronoun == "他" ? .male : .female, weight: 1, to: &votes)
            }
        }

        // 逐条建 Person，不再 map+元组解构：那一版的表达式编译器要推太久（真机 build 超时），
        // 而这里逐条摊开也没有别的好处可损失。
        var people: [Person] = []
        people.reserveCapacity(votes.count)
        for (name, tally) in votes {
            let marks = evidence[name] ?? Evidence(speaks: 0, addressed: 0)
            people.append(Person(
                name: name,
                gender: gender(male: tally.male, female: tally.female),
                maleVotes: tally.male,
                femaleVotes: tally.female,
                mentions: tally.mentions,
                attestations: marks.speaks,
                addressed: marks.addressed
            ))
        }
        return people.sorted { $0.mentions != $1.mentions ? $0.mentions > $1.mentions : $0.name < $1.name }
    }

    /// 投不满 2 票的判不出：孤证换错一整个人的性别，代价是这本书里他每句都错。
    ///
    /// 档案里也用它——那里拿的是**累计**票数，所以「这一批只投了一票」不再等于判不出，
    /// 后几批的票会接着往上加，加够才钉。钉过就不改口那条规则没变。
    static func gender(male: Int, female: Int) -> Gender {
        guard male != female else { return .unknown }
        let winner = max(male, female)
        guard winner >= minGenderVotes else { return .unknown }
        return male > female ? .male : .female
    }

    private static let minGenderVotes = 2

    /// 给人看的档案摘要，进 `[Roster]` 日志。名字和性别之间要有分隔，
    /// 否则「认真」+「男」连在一起看着就像一个叫「认真男」的人，日志就没法读了。
    ///
    /// 「达标」= 这一批里攒够了入档闸门（说过两次话 + 被称呼过）。**判定本身不再在这里做**，
    /// 那是 ``CharacterRoster`` 按全书累计的事，所以这一行只报「这批看到了谁」，
    /// 不报「档案里有谁」——档案的真实人数看最后一次扫完那行。
    static func summary(_ people: [Person]) -> String {
        let admitted = people.filter {
            ($0.attestations >= minSpeakerAttestations && $0.addressed >= 1)
                || (hasGenderTitle($0.name) && $0.attestations >= 1)
        }
        let known = admitted.filter { $0.gender != .unknown }
        let male = known.filter { $0.gender == .male }.count
        let listed = known.prefix(12)
            .map { "\($0.name)=\($0.gender == .male ? "男" : "女")(\($0.mentions))" }
            .joined(separator: "、")
        let unknown = admitted.count - known.count
        return "本轮候选 \(people.count) 个｜达标 \(admitted.count) 个｜定性别 \(known.count)（男 \(male)、女 \(known.count - male)）"
            + (listed.isEmpty ? "" : "｜\(listed)")
            + (unknown > 0 ? "｜判不出 \(unknown) 个用默认嗓" : "")
    }

    private static func add(
        _ name: String,
        gender: Gender,
        weight: Int,
        to votes: inout [String: (male: Int, female: Int, mentions: Int)]
    ) {
        guard var tally = votes[name] else { return }
        if gender == .male { tally.male += weight }
        if gender == .female { tally.female += weight }
        votes[name] = tally
    }

    private static func countMention(
        _ name: String,
        to votes: inout [String: (male: Int, female: Int, mentions: Int)]
    ) {
        guard var tally = votes[name] else { return }
        tally.mentions += 1
        votes[name] = tally
    }

    // MARK: - 候选人名

    /// 第二遍的成本是「句数 × 名字数」，名字多就得有个「先砍谁」的标准：留下的按**出场次数**
    /// 排。以前按说话次数排、打平按字面排，那是给「一批就扫完整本书」的老口径排的序，
    /// 而现在闸门按全书累计，一个名字下一轮还在不在候选里，直接决定它攒不攒得够证据——
    /// 出场多的那个人下次还会因为出场多而留下，按字母排则可能这轮留、下轮丢，账就断在路上了。
    static let maxCandidates = 400

    /// 一个名字要在这本书里被**认作说话人**两次以上才收进档案（``minSpeakerAttestations``），
    /// 但计数按全书累计，判定在 ``CharacterRoster``，不在这里。

    /// 一个候选串在这批正文里的两条独立信号：被认作说话人几次、被人当人称呼过几次。
    struct Evidence {
        let speaks: Int
        let addressed: Int
    }

    /// 档案收一个人的闸门，``CharacterRoster`` 按**全书累计**后判它。
    static let minSpeakerAttestations = 2

    private static func candidateNames(from chapterTexts: [[String]]) -> [String: Evidence] {
        var speakers: [String: Int] = [:]
        var addressed: [String: Int] = [:]
        var narration: [String] = []
        for text in chapterTexts.joined() {
            let piece = DialogueAttribution.maskDialogue(text)
            narration.append(piece)
            if let name = DialogueAttribution.personName(in: text) {
                speakers[name, default: 0] += 1
            }
            countAddressed(Array(piece), into: &addressed)
        }

        let mentions = mentionCounts(Array(speakers.keys), in: narration)
        return foldResidues(speakers, addressed: addressed, mentions: mentions)
    }

    /// 能带人称宾语的字（及物动词 + 引进对象的介词）。这是**闭口**集合，和首字姓表正好
    /// 管两个方向：姓表看这一串长什么样，这一条看它在句子里站哪个位置。
    ///
    /// 「终于」「简单」「上方」永远不会出现在这些字后面，而书里每一个真名都会——被人看见、
    /// 被人听见、被人叫到，是「书里确实有这个人」最硬的证据。首字姓表挡不住的残渣
    /// （终/简/上 都是姓表里放行过的字）就靠这一条筛掉。
    private static let personRelators: Set<String.Element> = [
        "看望见听到叫让对向朝跟和与同",
        "帮求劝谢夸骂打杀救护追拦牵抱扶",
        "推拉亲命派寻找问答念瞧喊吼理睬烦",
        "气爱恨怕欠赔送接带领请留骗吓雇访",
        "等盼想猜",
    ].reduce(into: Set<String.Element>()) { set, group in
        set.formUnion(group)
    }
    /// 「看到了宁毅」——动词和名字之间只许跨过这一个字的助词，再多就不是宾语了。
    private static let relatorParticles: Set<String.Element> = ["了", "着", "过"]
    /// 只有**动词**才跟得上这几个字（动态助词了/着/过、可能补语得、处所动词在）。
    /// 一个名字后面出现它们，说明这一串里最后那个字是谓语，不是人名的一部分
    /// ——见 ``countAddressed`` 里治「王林愣」入档那一条。
    private static let verbParticles: Set<String.Element> = ["了", "着", "过", "得", "在"]

    private static func countAddressed(
        _ characters: [String.Element],
        into counts: inout [String: Int]
    ) {
        var position = 0
        while position < characters.count {
            guard personRelators.contains(characters[position]) else {
                position += 1
                continue
            }
            // 动词后面那一个位置起 2~4 字，就是「被这个动词指着的人」。
            for start in [position + 1, position + 2]
            where start < characters.count
                && (start == position + 1 || relatorParticles.contains(characters[start - 1])) {
                let longest = min(DialogueAttribution.maxNameLength, characters.count - start)
                guard longest >= DialogueAttribution.minNameLength else { continue }
                for length in DialogueAttribution.minNameLength...longest {
                    let candidate = String(characters[start..<(start + length)])
                    guard DialogueAttribution.validPersonName(candidate) != nil else { continue }
                    // 三个字以上的串，后面紧跟动相助词时这一处**不是**这个名字：
                    // 「盯着王林愣了一下」里被盯的人是王林，「愣」是动词，「了」是它的动态助词。
                    // 这一条治的是入档那一路（见 ``CharacterRoster`` 的「被称呼≥1」闸门）：
                    // 一次「看向/盯着」会把 2、3、4 字各记一笔，于是「王林愣」这种
                    // 「姓+名+动」的残渣也攒够了「被当人称呼过」，跟真名一起进档案、各钉一把嗓，
                    // 同一个人的台词便一句旁白、一句男声地交替（用户报的第二条）。
                    // 只管三个字以上：两字的真名后面确实会跟「在/了」（「看见王林在门口」），
                    // 那一刀会砍到真人身上；而三字串撞上这种助词，几乎只会是残渣。
                    // 代价：真·三字名（「刘子羽」）在「X在家里」这一式里少记一笔称呼，
                    // 入档要的是一辈子≥1，别处「看向刘子羽。」就补上了。
                    let after = start + length
                    if length > DialogueAttribution.minNameLength, after < characters.count,
                       verbParticles.contains(characters[after]) { continue }
                    counts[candidate, default: 0] += 1
                }
            }
            position += 1
        }
    }

    /// 每个候选串在全书叙述里出现几次（台词内容不算）。按首字分桶再逐句数，和
    /// ``namesPresent`` 同一套省法：几百个串 × 几千句直接两两全扫，设备上一本书要几十秒。
    private static func mentionCounts(_ names: [String], in sentences: [String]) -> [String: Int] {
        let byFirst = Dictionary(grouping: names) { $0.first! }
        var counts: [String: Int] = Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
        for text in sentences {
            for character in Set(text) {
                guard let group = byFirst[character] else { continue }
                for name in group {
                    counts[name, default: 0] += occurrences(of: name, in: text)
                }
            }
        }
        return counts
    }

    private static func occurrences(of target: String, in text: String) -> Int {
        guard !target.isEmpty else { return 0 }
        var hits = 0
        var search = text.startIndex
        while let found = text.range(of: target, range: search..<text.endIndex) {
            hits += 1
            search = text.index(after: found.lowerBound)
        }
        return hits
    }

    /// 把「真名 + 剥不干净的尾巴」并回真名。三个方向，全都往**更短、且书里确实出现过**的
    /// 串上并，绝不反过来砍短：
    /// ①「韩立师兄」——名字打头、称谓收尾；
    /// ②「赵玖背身」「宁毅看看」——名字打头、后面挂着表里没写的状语或动词；
    /// ③「只见韩立」——提示语最多吃进 12 个字，所以修饰可能在前、名字在后。
    ///
    /// ② 的判据**通常**是出场次数，不是「当说话人的次数」：分句主语那条形状（③）产出的残渣
    /// 恰恰最常当说话人（「宁毅看看旁边的周佩与周君武，这才笑着问道：“…”」），拿说话人
    /// 次数比就变成「宁毅看」赢过「宁毅」，同一个人两把嗓——实测就是这么错的。
    /// 比之前还要先扣掉「作为更长名字的一截」出现的那部分：「苏檀」的 608 次全都包在
    /// 「苏檀儿」里，扣完归零，于是它不会把苏檀儿吃掉；「宁毅」扣掉「宁毅看」那些次还是压倒性。
    /// 唯一的例外是四个字的串（见下面 `shapeVoid` 那段）：形状已经判死它不是名字，
    /// 就不必再等次数——等次数那一关正是配角脏名入档的路。
    private static func foldResidues(
        _ speakers: [String: Int],
        addressed: [String: Int],
        mentions: [String: Int]
    ) -> [String: Evidence] {
        var counts: [String: Int] = [:]
        var addressEvidence = addressed
        var own = mentions
        // 长的先扣：扣完它自己就不再是更短那截的一部分了。
        for name in speakers.keys.sorted(by: { $0.count > $1.count }) {
            for length in DialogueAttribution.minNameLength..<name.count {
                let prefix = String(name.prefix(length))
                guard own[prefix] != nil else { continue }
                own[prefix, default: 0] -= own[name, default: 0]
            }
        }
        for (name, count) in speakers {
            let stem = DialogueAttribution.stem(name)
            let head = own[stem, default: 0] > 0 ? stem : name
            var target = head
            // 「杨毅焦急」「赵玖恍然」这种四个字的串**按形状**就不是名字：汉字名字到四字只有
            // 复姓打头、称谓收尾两种写法（``DialogueAttribution/explainableLongName``），
            // 剩下的都是提示语把状语一起吃进了名字（用户报的第一条）。这种串不许单独立档——
            // 它一进档案就钉一把自己的嗓，同一个人的台词一句男声一句旁白交替（用户报的第二条）。
            // 为什么这一刀不看出场次数：按次数的并档（``CharacterRoster/prefixFolds``）是照
            // 主角的量定的，绍宋里杨毅出场不到 20 次，脏串「杨毅焦急」折不动、照样入档。
            // 形状是闭口表判出来的，比次数硬，所以它绕过次数那一关直接并。
            let shapeVoid = head.count >= DialogueAttribution.maxNameLength
                && !DialogueAttribution.explainableLongName(head)
            // 从**最短**的那截试起，第一个压得住的就是名字。反过来（先试长的）会把残渣
            // 并到另一个残渣上：「宁毅看他」→「宁毅看」→ 档案里就多出一个叫「宁毅看」的人，
            // 和「宁毅」两把嗓——实测就是这样留下了 宁毅看。
            for length in DialogueAttribution.minNameLength..<max(head.count, DialogueAttribution.minNameLength) {
                let prefix = String(head.prefix(length))
                guard speakers[prefix] != nil else { continue }
                guard shapeVoid || (own[prefix] ?? 0) >= (own[head] ?? 0) else { continue }
                target = prefix
                break
            }
            // 形状判死、前缀里又没有一个人当过说话人：这一串的「说过话」整笔丢掉。
            // 宁可那句退回旁白（听感是没人换嗓），也不能让一个不存在的人拿走一把嗓。
            if shapeVoid, target == head { continue }
            counts[target, default: 0] += count
            // 残渣并入真名时，它那条「被人称呼过」的证据要跟着一起并过去。
            addressEvidence[target, default: 0] += addressEvidence[name] ?? 0
        }
        var merged: [String: Int] = [:]
        for name in counts.keys.sorted(by: { $0.count < $1.count }) {
            // 只许并到**称呼词**上（姑娘/大人/师兄…）。原来那种「谁的尾巴短就并给谁」
            // 会把「处处小心」并到「小心」、把「万分认真」并到「认真」——残渣吸走一堆
            // 不同人的台词，档案里就多出一个名叫「小心」的人，比留着两条更糟。
            let shorter = merged.keys
                .filter { $0 != name && name.hasSuffix($0) && isAddressWord($0) }
                .max(by: { $0.count < $1.count })
            merged[shorter ?? name, default: 0] += counts[name] ?? 0
        }

        // 前缀型的残渣（「艾丽」每次都在「艾丽斯」里）上面那圈 hasSuffix 并不动，
        // 但它扣完的独立出场次数是 0——书里从来没有单独叫过这个名字，是同一个人被切短了，
        // 档案里留两条就是同一个人两把嗓。盘龙实测 梅丽/梅丽特、艾丽/艾丽斯 各 147/332 次，
        // 次数一模一样，正是这一类。
        // 只往**独立次数仍然 >0** 的那个长名上并：并到一个同样会被并走的中间名上，
        // 次数就丢在半路了。
        for shorter in merged.keys.sorted(by: { $0.count > $1.count }) {
            guard (own[shorter] ?? 0) <= 0 else { continue }
            let candidates = merged.keys.filter { longer in
                longer != shorter && longer.hasPrefix(shorter) && (own[longer] ?? 0) > 0
            }
            guard let longer = candidates.sorted(by: {
                $0.count != $1.count ? $0.count > $1.count : $0 < $1
            }).first else { continue }
            let count = merged[shorter] ?? 0
            merged[shorter] = nil
            merged[longer, default: 0] += count
            addressEvidence[longer, default: 0] += addressEvidence[shorter] ?? 0
        }

        // 两道闸门**都不在这里判**，只把数报出去：扫描是一批一批喂进来的（设备 7 章一轮），
        // 按批次判「说过两次话」会让每章只说一次的人轮轮不达标，整本书几百句台词压在
        // 无名嗓上——绍宋实测 7 章入档 0 人、整本扫 111 人。累计与判定在 ``CharacterRoster``。
        //
        // 但第二遍的成本是「句数 × 名字数」，所以这里仍留前 ``maxCandidates`` 个。
        // 排序按**出场次数**： merged 的键个个都说过话（它们全是从说话人串来的），
        // 所以这一刀砍掉的是「说过一两次、书名场面也少」的长尾，而不是随机一批名字。
        let ranked = merged.sorted {
            let lhs = own[$0.key] ?? 0
            let rhs = own[$1.key] ?? 0
            if lhs != rhs { return lhs > rhs }
            return $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.prefix(maxCandidates)
        var kept: [String: Evidence] = [:]
        for (name, speaks) in ranked where speaks > 0 {
            kept[name] = Evidence(speaks: speaks, addressed: addressEvidence[name] ?? 0)
        }
        return kept
    }

    private static func namesPresent(
        _ text: String,
        byFirstCharacter: [String.Element: [String]]
    ) -> [String] {
        // 先按首字筛：几百个名字逐句 range(of:) 是几千万次字符串查找，
        // 而句子里没有这个首字就必然没有这个名字。
        var hits: [String] = []
        for character in Set(text) {
            guard let group = byFirstCharacter[character] else { continue }
            for name in group where !hits.contains(name) && text.range(of: name) != nil {
                hits.append(name)
            }
        }
        return hits
    }

    // MARK: - 段内承前

    /// 一句「光秃秃的引号」能不能借同段上一句的说话人。
    ///
    /// 为什么默认不做：中文网文里大量台词是旁边一个字都没写的「“……”」，局部规则结构上
    /// 判不出是谁。上一句刚点过名的那个人是最像的答案，但**像**不等于**是**——同段里连着
    /// 两句裸引号通常是一问一答，借过去就是把 A 的台词安上 B 的腔调，那是需求里禁止的错，
    /// 而认不出来退回无名嗓是一致且无害的。所以这里把三条风险一起关掉：
    ///
    /// - **单跳、不续借**：借据必须是「现从上一句的叙述里抽出来的」，而不是上一句自己借来的。
    ///   抽不到就不借，于是同一个人口里的第三句就不再跟着并过来。
    /// - **只借本段第一处归属**：段里如果先有别人说过话，那这一段就在轮流说话，
    ///   这一句裸引号更可能是另一个人的答话。
    /// - **借来的名字必须在人物档案里查得到**（``CharacterRoster/person(bookID:name:)``）：
    ///   查不到就不借，绝不为一个借来的串开新嗓。这一条同时把「杨沂中主」「赵玖一时」那种
    ///   残渣收进档案里那个真名，两句仍是同一把嗓。
    ///
    /// 闸门 `enabled` 由 ``quotePairing(_:paragraphStarts:)`` 的每本书结论决定（见 ``CharacterRoster/allowsParagraphCarry``）：
    /// 引号成对不干净的书，`maskDialogue` 会把整段的引号内外翻过来，「段里的上一句」根本不是同一个人。
    static func carriedSpeaker(
        at index: Int,
        texts: [String],
        paragraphStarts: [Bool],
        knownNames: Set<String>,
        rosterName: (String) -> String?,
        enabled: Bool
    ) -> String? {
        guard enabled, index > 0, index < texts.count else { return nil }
        // 本句根本没有人在开口（叙述里嵌了一段引用）就不借：借据在上一句那边，
        // 只在上半道设闸门的话，这类句子会照样把上一句的说话人领走，换出同一把「旁白换人」。
        guard DialogueAttribution.speaksInThisSentence(texts[index]) else { return nil }
        // 本句带「新起一段」标记的话，上一句就是**另一段**的，不借。
        guard index >= paragraphStarts.count || !paragraphStarts[index] else { return nil }
        guard let direct = DialogueAttribution.personName(in: texts[index - 1], knownNames: knownNames),
              let borrowed = rosterName(direct) else { return nil }
        // 上一句得是本段里**第一处**认得出人的：往回看到段首，中间再有一处就不借。
        var cursor = index - 1
        while cursor > 0, cursor >= paragraphStarts.count || !paragraphStarts[cursor] {
            cursor -= 1
            if DialogueAttribution.personName(in: texts[cursor], knownNames: knownNames) != nil { return nil }
        }
        return borrowed
    }

    /// 引号配对干不干净：一个**段落**里开引号与闭引号数目不等，话头就跨到了别处。
    ///
    /// 这是段内承前的门槛（见 ``carriedSpeaker``）。为什么按段落而不是按句子：断句器本来就会
    /// 把一段话里的几个句子切开，于是一段台词只有第一句带「“」、最后一句带「”」——
    /// 绍宋 60 章实测**句子级 23.9% 不配、段落级 0.0%**，拿句子级当闸门会把每一本正常排版的书
    /// 都判成劣化，承前就永远开不了。真正的病是引号**跨过段落**（扫描版一段一句、有话没头没尾
    /// 那种），只有那种书上「同段上一句」和「这句是谁说的」才真的没关系。
    /// 分母只算**带引号的段落**：一句台词都没有的段落无从配对。
    static func quotePairing(_ texts: [String], paragraphStarts: [Bool]) -> QuotePairing {
        let opens = Set("\u{201C}\u{2018}\u{300C}\u{300E}")
        let closes = Set("\u{201D}\u{2019}\u{300D}\u{300F}")
        // 段落标记缺失就退回「一句一段」：那是最保守的读法（每句各自配对），
        // 只会把书判得更脏，不会误开门。
        let starts = paragraphStarts.count == texts.count ? paragraphStarts : nil
        var total = 0, unbalanced = 0, opened = 0, closed = 0
        func flush() {
            if opened > 0 || closed > 0 {
                total += 1
                if opened != closed { unbalanced += 1 }
            }
            opened = 0
            closed = 0
        }
        for (index, text) in texts.enumerated() {
            let beginsParagraph = index == 0 || starts.map { $0[index] } ?? true
            if beginsParagraph { flush() }
            for character in text {
                if opens.contains(character) { opened += 1 }
                else if closes.contains(character) { closed += 1 }
            }
        }
        flush()
        return QuotePairing(unbalanced: unbalanced, total: total)
    }

    /// 一批章（每章一组句子 + 每句是否新起一段）的配对数，用于跨章累计。
    /// 章首那句必然是新段落，所以各章的段落互不相干，直接相加。
    static func quotePairing(chapters: [[String]], paragraphStarts: [[Bool]]) -> QuotePairing {
        var merged = QuotePairing(unbalanced: 0, total: 0)
        for (index, chapter) in chapters.enumerated() {
            let one = quotePairing(chapter, paragraphStarts: index < paragraphStarts.count ? paragraphStarts[index] : [])
            merged.unbalanced += one.unbalanced
            merged.total += one.total
        }
        return merged
    }

    struct QuotePairing {
        var unbalanced: Int
        var total: Int

        /// 脏到什么程度就不许借名。跑真书探针会打印每本书的实际比例，这条线按那些数字定。
        static func isClean(_ pairing: QuotePairing) -> Bool {
            guard pairing.total > 0 else { return false }
            return Double(pairing.unbalanced) * 100 <= Double(pairing.total) * 5
        }
    }

    // MARK: - 线索

    /// 名字尾巴上的称谓。只认**结尾**：「王」是姓，「王婶」才是称谓。
    private static let femaleTitles = [
        "婶", "姨", "姐", "妹", "婆", "奶", "妈", "娘", "嫂", "姑", "姑娘", "小姐", "女士",
        "太太", "夫人", "公主", "妃", "嬷嬷", "侍女", "婢", "少女",
        // 「柳氏」「张氏」：随夫姓称呼的已婚女子，这个「氏」就是性别标记本身，等不到代词。
        "氏",
        // 后半批是绍宋实测补的：那一本 437 章里判出 52 个性别、**一个女的都没有**，
        // 因为书里说话的女人全叫「郑太后」「吴贵妃」「某帝姬」「某娘子」，而「后/贵妃/
        // 帝姬/娘子」这四个字面不在这张表上——她们的台词于是全压在男声池里。
        // 「女子/女人/妇人」和男表里的「男子/少年」同一类：没有名字、光靠这个词说话的
        // 人，词本身就是那把嗓的性别。
        "贵妃", "帝姬", "娘子", "妇人", "女子", "女人", "主母", "妾",
        // 「后」必须**带着前面的字**才算称谓：裸一个「后」字会把「许久之后」（绍宋实测被抽成
        // 说话人 3 次）收成女角——而档案对带称谓的人是**说过一次话就收**（``CharacterRoster/merge``
        // 那条例外），于是这个口子拦不住任何脏名，只会把脏名收成女人。
        // 「女」同理删掉：「完颜活女」是**男的**（金将），裸字当称谓就等于给他钉一把女嗓。
        "太后", "皇后", "王后", "帝后",
    ]
    private static let maleTitles = [
        "叔", "伯", "哥", "弟", "爷", "翁", "爹", "爸", "兄", "公子", "少爷", "长老", "大师",
        "道士", "和尚", "僧", "大侠", "老爷子", "大爷", "大叔",
        // 「少年说道」「那汉子道」这种没有名字、只有一个性别名词的说话人：这个词本身就
        // 是那把嗓的性别，不用等第二句里的代词来投票。
        "少年", "男子", "男人", "青年", "大汉", "汉子",
        // 绍宋实测补的两个：**独指**的官称。「吕相公」就是吕颐浩、「赵官家」「官家」就是
        // 皇帝，书里不会有两个相公、两个官家，所以这两个字面本身就是性别证据，等不到代词。
        // 「大人」不在此列——男女都能称大人，它不是性别证据。
        "相公", "官家",
        // 「大太子终/大太子完/大太子斡」是绍宋实测抽到的三个串（尾巴分别是「终于」「完颜」「斡……」
        // 的首字）：加了「太子」这一档，``DialogueAttribution/untailGenderTitle`` 才切得动它们。
        "太子",
    ]

    /// **独指**称呼：一本书里只会有一个人的那种（一个皇帝、一个太后、一个丞相）。
    /// 这一张表存在的唯一理由是「赵官家」这类写法：姓 + 称呼，``DialogueAttribution/stem``
    /// 砍到底只剩一个「赵」，低于 ``DialogueAttribution/minNameLength``，所以并不到「赵玖」身上
    /// ——实测绍宋 赵玖（出场 4936）和 赵官家（出场 3714、被人当面叫过 1892 次）各占档案一条，
    /// 配到两把不同的男嗓，正是需求里禁止的「同一个人两段对话换个声音」。
    /// 只有列在这里的称呼允许这样并档，因为并档的前提是「这个称呼在书里只有一个主人」；
    /// 「大人/将军/先生」谁都能被这么叫，绝不在内。
    private static let soleRoleTitles = [
        "官家", "皇帝", "太后", "皇后", "贵妃", "公主", "丞相", "相公", "王爷", "太子",
    ]

    /// 这个名字是不是「单字姓 + 独指称呼」这种写法，是就给出那个姓。
    /// 档案拿它做并档（见 ``CharacterRoster`` 的 `aliases`），判定只在这张闭口表上查表尾。
    /// 返回 `String` 而不是裸 `Character`：这个模块里 `Character` 是书里那个人
    /// （Models/Character.swift），写 `Character?` 会静默指到它身上去。
    static func soleRoleSurname(of name: String) -> String? {
        guard let title = soleRoleTitles.first(where: { name.hasSuffix($0) }),
              name.count > title.count,
              name.count - title.count == 1
        else { return nil }
        return String(name.prefix(1))
    }

    /// 这个名字的字面里有没有**性别称谓**（太后/贵妃/帝姬/娘子/氏/相公/官家…）。
    ///
    /// 档案收人时这条是「一句话证据」：``CharacterRoster`` 允许带称谓的人只说过一次话就入档。
    /// 为什么单单给称谓开这个口子——绍宋 437 章实测：女角**一次都没被抽成说话人**的写法是常态
    /// （她们在叙述里被提到、在台词里被说起，轮不到「郑太后道：“…”」这种形状），于是
    /// 「说过两次话」这道闸门把书里所有女人拦在档案之外，判出性别的 50 人里女的是 **0** 个，
    /// 而那几句确确实实落到她们身上的台词，全压在一把男嗓上。
    /// 称谓是**闭口**集合（就那几十个词），而「她是谁」写在字面上，不需要投票——
    /// 这跟「靠代词猜性别然后只说过一次话就收」是两件事，后者依然要过闸门。
    static func hasGenderTitle(_ name: String) -> Bool {
        femaleTitles.contains { name.hasSuffix($0) } || maleTitles.contains { name.hasSuffix($0) }
    }

    private static func titleSignal(_ name: String) -> (gender: Gender, weight: Int)? {
        if femaleTitles.contains(where: { name.hasSuffix($0) }) { return (.female, 3) }
        if maleTitles.contains(where: { name.hasSuffix($0) }) { return (.male, 3) }
        return nil
    }

    /// 这个词能不能单独用来叫人（辈分称谓、官称、性别名词）。闭口集合：三张表列完就完了。
    ///
    /// 归并残渣时它当闸门：只有尾巴本身是个称呼词，才允许把长的并到短的上面去
    /// （「白须姑娘」并到「姑娘」是对的，「处处小心」并到「小心」是把一堆不同人的台词
    /// 交给一个根本不存在的人）。
    private static func isAddressWord(_ word: String) -> Bool {
        femaleTitles.contains(word) || maleTitles.contains(word) || DialogueAttribution.isRelationTitle(word)
    }

    /// 句子里点到性别的名词：只用来判「**这个名词说的就是这个人名**」那两种写法。
    ///
    /// 旧写法是「同一句里出现性别词，就给句中每个候选名投一票」，真书一测就把男主判错了：
    /// 赘婿的宁毅拿到 男139/女175——因为描写女性时用的「姑娘/妇人/女子」满书都是，
    /// 而「宁毅看着那姑娘」里的姑娘压根不是宁毅。性别词必须**紧贴**名字才作数。
    private static let maleNouns = [
        "男子", "男人", "小伙", "少年", "青年", "壮汉", "大汉", "汉子", "大叔", "大爷", "老头", "老者",
        "老爷子", "先生", "公子", "少爷", "师兄", "师弟", "和尚", "道士", "武僧", "男修",
    ]
    private static let femaleNouns = [
        "女子", "女人", "姑娘", "少女", "女孩", "妇人", "少妇", "婆婆", "奶奶", "大妈", "阿姨", "小姐",
        "女士", "太太", "公主", "师姐", "师妹", "女修",
    ]
    /// 「年轻人」这种中性说法两张表都不进：进了就等于给同句的人随便投票。
    /// 「韩立的妻子」→ 韩立是男的：配偶名词说明的是**名字主人**的性别，方向正好反过来。
    /// 只在「名字 + 的 + 这个名词」里作数（同位语写法「妻子苏檀儿」反过来，用上面两张表）。
    private static let partnerNouns: [(String, Gender)] = [
        ("妻子", .male), ("老婆", .male), ("媳妇", .male), ("娘子", .male), ("女朋友", .male),
        ("丈夫", .female), ("老公", .female), ("男朋友", .female),
    ]
    /// 名字和性别词之间只许跨过这些连接字——跨过动词就不是同一个人了。
    private static let bindingParticles: Set<String.Element> = [
        "的", "个", "位", "这", "那", "一", "名", "只", "是", "小",
    ]

    /// 紧贴名字的性别词。三种形状：
    /// ①「少年韩立」「那姑娘苏晴」——性别词在名字**前面**，中间只隔连接字；
    /// ②「韩立的妻子」——名字后面是「的」+ 配偶名词；
    /// ③「苏檀儿是个姑娘」「他乃是本院师兄」——名字后面是「是/为/乃」+ 性别名词。
    /// 都不看隔了一个**其它**动词的同句名词，那是本书里另一个人的性别。
    /// ③ 是代词口径收紧成话题位之后补的：话题位只认真正当主语的代词，代价是覆盖率掉
    /// （赘婿主要角色从 60% 掉到 41.7%），而「X 是个姑娘」这种判断句没有歧义，能白捡一批。
    private static func boundGender(_ text: String, name: String) -> Gender? {
        let characters = Array(text)
        let nameCharacters = Array(name)
        var position = 0
        while let hit = range(of: nameCharacters, in: characters, from: position) {
            let after = hit.upperBound
            if characters.indices.contains(after), characters[after] == "的" {
                var cursor = after + 1
                if cursor < characters.count, bindingParticles.contains(characters[cursor]) { cursor += 1 }
                if let gender = partnerGender(characters, at: cursor) { return gender }
            }
            if characters.indices.contains(after), identityVerbs.contains(characters[after]) {
                var cursor = after + 1
                var skipped = 0
                while cursor < characters.count, skipped < 2, bindingParticles.contains(characters[cursor]) {
                    cursor += 1
                    skipped += 1
                }
                let descending = (maleNouns + femaleNouns).sorted { $0.count > $1.count }
                for word in descending where matches(characters, word, at: cursor) {
                    return femaleNouns.contains(word) ? .female : .male
                }
            }
            var before = hit.lowerBound
            var skipped = 0
            while before > 0, skipped < 2, bindingParticles.contains(characters[before - 1]) {
                before -= 1
                skipped += 1
            }
            if let gender = nounGender(characters, endingAt: before) { return gender }
            position = after
        }
        return nil
    }

    /// 判断句的系词：名字后面跟它，后面的性别词说的就是这个人。
    private static let identityVerbs: Set<String.Element> = ["是", "为", "乃"]

    private static func partnerGender(_ characters: [String.Element], at start: Int) -> Gender? {
        for (word, gender) in partnerNouns where matches(characters, word, at: start) { return gender }
        return nil
    }

    /// 以 `end`（不含）结尾的那个性别名词。两张表**不许有重叠词**，所以匹配上就按它走。
    private static func nounGender(_ characters: [String.Element], endingAt end: Int) -> Gender? {
        let descending = (maleNouns + femaleNouns).sorted { $0.count > $1.count }
        for word in descending where end >= word.count && matches(characters, word, at: end - word.count) {
            return femaleNouns.contains(word) ? .female : .male
        }
        return nil
    }

    private static func matches(
        _ characters: [String.Element],
        _ word: String,
        at start: Int
    ) -> Bool {
        let letters = Array(word)
        guard start >= 0, start + letters.count <= characters.count else { return false }
        return Array(characters[start..<(start + letters.count)]) == letters
    }

    private static func range(
        of target: [String.Element],
        in characters: [String.Element],
        from start: Int
    ) -> Range<Int>? {
        guard !target.isEmpty, start <= characters.count - target.count else { return nil }
        var index = start
        while index + target.count <= characters.count {
            if Array(characters[index..<(index + target.count)]) == target {
                return index..<(index + target.count)
            }
            index += 1
        }
        return nil
    }

    /// ③ 名字之后的 他/她，**只认站在话题位的那一个**。
    ///
    /// 话题位 = 它自己或它所属的名字正处在**分句开头**：前面是分隔符，或者只跨过几个连接
    /// 副词（但/却/便/随后…）。这条取代了旧的「宾语位置」判据——那一版只挡「及物动词
    /// （+了着过）+ 代词」，而及物动词是**开口集**，真书里啐、僵、递、搂、拉一个都不在表上。
    /// 庆余年第 101~160 章实测女角全被判男（林婉儿 男15/女4、范若若 13/6、柳氏 7/3），
    /// 票源全是同一形状：「林婉儿略带歉意地看了他一眼」「范若若此时递了张纸给他」
    /// 「近侍…将柳氏扶了正，这皇帝就将他扶了正」——名字后面挂了个动词，动词后面那个「他」
    /// 是**句子里另一个男人**，却记进了女主的票。反过来「林婉儿并不惊讶，…她便知道」
    /// 「宁毅想了想，随后他伸手」这种才是真的自指，一条都不能少。
    ///
    /// 名字本身也必须在话题位：「坐在林婉儿的身边，盯着她的脸蛋」里名字是宾语、代词是
    /// 领属，两处都不是主语，一句都不该投。
    ///
    /// 仍然作废的两种：中间冒出**另一个候选名**（「宁毅看着苏檀儿，她觉得…」的她是苏檀儿）、
    /// 跨过**句号**（换了句子就换了主语）。跨句的主语延续由 ④ 单独处理，不在这条里混。
    ///
    /// 不是 private 只为取证：真书探针拿它逐句复算「这个名字的男票到底是从哪句来的」，
    /// 判反性别这种事靠猜规则猜不出来（见 `.probe/corpus/main.swift`）。
    static func pronounAfter(
        _ text: String,
        name: String,
        otherNames: [String]
    ) -> String? {
        let characters = Array(text)
        let letters = Array(name)
        let others = otherNames.map(Array.init)
        guard !letters.isEmpty, letters.count <= characters.count else { return nil }
        var position = 0
        while let hit = range(of: letters, in: characters, from: position) {
            position = hit.upperBound
            // 只从**当主语的那次出现**往后看：「范闲死死盯着林婉儿，他…」不算林婉儿的证据。
            guard atTopicPosition(characters, at: hit.lowerBound) else { continue }
            // 名字紧跟着「的」：后面那个她是「苏檀儿的女儿」里的人。
            if position < characters.count, characters[position] == "的" { continue }
            let limit = min(characters.count, position + 40)
            var cursor = position
            while cursor < limit {
                let current = characters[cursor]
                if sentenceEnds.contains(current) { break }
                if others.contains(where: { starts($0, at: cursor, in: characters) }) { break }
                if current == "他" || current == "她" {
                    // 两种算数：贴着名字的同位写法（「林婉儿她也正望着」），或代词自己站在
                    // 话题位（「……，她便知道」「庄墨韩淡淡的道，他的话音很轻」——领属写法
                    // 只要处在话题位就照样作数，不需要特例）。
                    // 特例反而会把女主的票全毒掉：庆余年实测林婉儿 8 张男票**无一例外**是
                    // 「啐了他一口 / 拉着他的袖角 / 靠在他的怀里 / 倚在了他的怀里」——
                    // 代词前面是动词或介词，那个他是范闲。
                    if cursor == position || atTopicPosition(characters, at: cursor, beyond: position) {
                        return String(current)
                    }
                }
                cursor += 1
            }
        }
        return nil
    }

    /// 分句的分隔符：话题位的左边界。引号也算——台词前后引号就是叙述段落的边界。
    private static let topicSeparators: Set<String.Element> = [
        "，", "、", "；", "：", "。", "！", "？", "…", "\n", "\u{201C}", "\u{201D}", "「", "」",
    ]
    /// 话题位前面允许跨过的连接字。都是**副词/连词/指代词**，一个动词都不进——
    /// 所以「看着他的」这种绝不会被当成话题位，而「随后他」「但她」「那少年」会。
    /// 最多跨 2 个（「于是」「随后」「可此时」这类两字连接词）。
    private static let topicConnectives: Set<String.Element> = [
        "但", "却", "便", "就", "也", "又", "还", "只", "已", "而", "并", "且", "于", "是",
        "随", "后", "才", "则", "即", "既", "虽", "这", "那", "另", "外", "均", "皆", "紧", "接",
    ]

    /// `index` 处是不是分句开头：往前最多跨 2 个连接字，必须撞到分隔符或句首。
    /// `beyond` 给的是「不许越过的位置」（代词判定时=名字结尾，防止跨过名字去认上半句的分隔符）。
    private static func atTopicPosition(
        _ characters: [String.Element],
        at index: Int,
        beyond: Int? = nil
    ) -> Bool {
        var before = index
        var skipped = 0
        while before > 0, skipped < 2 {
            if let beyond, before <= beyond { return false }
            guard topicConnectives.contains(characters[before - 1]) else { break }
            before -= 1
            skipped += 1
        }
        if let beyond, before < beyond { return false }
        return before == 0 || topicSeparators.contains(characters[before - 1])
    }

    /// 名字在这个句子里**至少有一次**站在话题位（当主语，不是「看着林婉儿」那种宾语）。
    private static func isTopicName(_ text: String, name: String, in characters: [String.Element]) -> Bool {
        let letters = Array(name)
        var position = 0
        while let hit = range(of: letters, in: characters, from: position) {
            if atTopicPosition(characters, at: hit.lowerBound) { return true }
            position = hit.upperBound
        }
        return false
    }

    /// ④ 的前半：这句**开头**就是 他/她（允许先跨过连接字，「但他…」「随后她…」）。
    /// 「他们」不算——一群人没有单指的嗓。不是 private 只为取证。
    static func leadingPronoun(_ text: String) -> String? {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !characters.isEmpty else { return nil }
        var index = 0
        while index < characters.count, index < 2, topicConnectives.contains(characters[index]) {
            index += 1
        }
        guard index < characters.count else { return nil }
        let current = characters[index]
        guard current == "他" || current == "她" else { return nil }
        if index + 1 < characters.count, characters[index + 1] == "们" { return nil }
        return String(current)
    }

    /// ④ 的后半：上一句里**只有一个**候选名、而且它当过主语，那个人就是本句「他」指的人。
    /// 上一句里出现第二个名字就整条作废——两个人共享一句，谁被代词接着说没有确定答案。
    private static func carriedSubject(
        _ previous: String?,
        byFirstCharacter: [String.Element: [String]]
    ) -> String? {
        guard let previous else { return nil }
        let present = namesPresent(previous, byFirstCharacter: byFirstCharacter)
        guard present.count == 1 else { return nil }
        let characters = Array(previous)
        guard isTopicName(previous, name: present[0], in: characters) else { return nil }
        return present[0]
    }

    private static let sentenceEnds: Set<String.Element> = ["。", "！", "？", "…", "\n"]

    private static func starts(
        _ name: [String.Element],
        at index: Int,
        in characters: [String.Element]
    ) -> Bool {
        guard !name.isEmpty, index + name.count <= characters.count else { return false }
        return Array(characters[index..<(index + name.count)]) == name
    }
}
