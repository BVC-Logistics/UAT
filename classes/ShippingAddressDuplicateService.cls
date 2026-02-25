public class ShippingAddressDuplicateService {
   private static Decimal THRESHOLD = 0.30;

    /* ================================================
       MAIN METHOD - Run for a single customer
    ================================================ */
    public static void processCustomer(Id accountId) {
 
        
    // STEP 0 - Clear ALL AI codes for this customer regardless of Record Type
    List<AddressBook__c> allAddrs = [
        SELECT Id, AI_short_code__c
        FROM AddressBook__c
        WHERE Customer__c = :accountId
        AND AI_short_code__c != null
    ];
    for (AddressBook__c a : allAddrs) {
        a.AI_short_code__c = null;
    }
    if (!allAddrs.isEmpty()) {
        Database.update(allAddrs, false);
    }
       //fetches the unique salesforce id for the shipping Record type
        Id shippingRT =
            Schema.SObjectType.AddressBook__c
                .getRecordTypeInfosByDeveloperName()
                .get('Shipping')
                .getRecordTypeId();

        // STEP 1 - Fetch all shipping addresses by RecordType
        List<AddressBook__c> addrs = [
            SELECT Id, Name, City__c, Pincode__c, AI_short_code__c
            FROM AddressBook__c
            WHERE Customer__c = :accountId
            AND RecordTypeId = :shippingRT
            AND City__c != null
            AND Pincode__c != null
            ORDER BY Pincode__c, City__c, Name
        ];

        if (addrs.isEmpty()) {
            System.debug('No shipping addresses found for: ' + accountId);
            return;
        }

        System.debug('Total addresses found: ' + addrs.size());

        // STEP 2 - Clear existing codes first
        for (AddressBook__c a : addrs) {
            a.AI_short_code__c = null;
        }
        Database.update(addrs, false);

        // STEP 3 - Re-query fresh after clearing
        addrs = [
            SELECT Id, Name, City__c, Pincode__c, AI_short_code__c
            FROM AddressBook__c
            WHERE Customer__c = :accountId
            AND RecordTypeId = :shippingRT
            AND City__c != null
            AND Pincode__c != null
            ORDER BY Pincode__c, City__c, Name
        ];

        // STEP 4 - Bucket by Pincode + City (preserve insertion order)
        Map<String, List<AddressBook__c>> buckets = new Map<String, List<AddressBook__c>>();
        List<String> keyOrder = new List<String>();

        for (AddressBook__c a : addrs) {
            String key = normalize(a.Pincode__c + ' ' + a.City__c);
            if (!buckets.containsKey(key)) {
                buckets.put(key, new List<AddressBook__c>());
                keyOrder.add(key);
            }
            buckets.get(key).add(a);
        }

        // STEP 5 - Fuzzy match and assign codes
        Integer seq = 1;
        List<AddressBook__c> toUpdate = new List<AddressBook__c>();

        for (String k : keyOrder) {
            List<AddressBook__c> grp = buckets.get(k);

            Boolean[] used = new Boolean[grp.size()];
            for (Integer i = 0; i < used.size(); i++) used[i] = false;

            for (Integer i = 0; i < grp.size(); i++) {
                if (used[i]) continue;

                List<AddressBook__c> dup = new List<AddressBook__c>();
                dup.add(grp[i]);
                used[i] = true;

                String base = normalize(
                    grp[i].Name + ' ' + grp[i].City__c + ' ' + grp[i].Pincode__c
                );

                for (Integer j = i + 1; j < grp.size(); j++) {
                    if (used[j]) continue;

                    String cmp = normalize(
                        grp[j].Name + ' ' + grp[j].City__c + ' ' + grp[j].Pincode__c
                    );

                    if (tokenSimilarity(base, cmp) >= THRESHOLD) {
                        dup.add(grp[j]);
                        used[j] = true;
                    }
                }

                // Assign code to ALL including singles
                String code = 'AI-' + String.valueOf(seq).leftPad(3, '0');
                seq++;

                for (AddressBook__c r : dup) {
                    r.AI_short_code__c = code;
                    toUpdate.add(r);
                }
            }
        }

        // STEP 6 - Update with partial success
        if (!toUpdate.isEmpty()) {
            List<Database.SaveResult> results = Database.update(toUpdate, false);
            Integer success = 0;
            Integer failed = 0;
            for (Database.SaveResult r : results) {
                if (r.isSuccess()) {
                    success++;
                } else {
                    failed++;
                    System.debug('FAILED ID: ' + r.getId() +
                                 ' | Error: ' + r.getErrors()[0].getMessage());
                }
            }
            System.debug('SUCCESS: ' + success + ' | FAILED: ' + failed);
        }
    }

    /* ================================================
       RUN FOR ALL CUSTOMERS
    ================================================ */
    public static void processAllCustomers() {

        Id shippingRT =
            Schema.SObjectType.AddressBook__c
                .getRecordTypeInfosByDeveloperName()
                .get('Shipping')
                .getRecordTypeId();

        Set<Id> customerIds = new Set<Id>();
        for (AddressBook__c a : [
            SELECT Customer__c
            FROM AddressBook__c
            WHERE RecordTypeId = :shippingRT
            AND Customer__c != null
        ]) {
            customerIds.add(a.Customer__c);
        }

        System.debug('Total customers to process: ' + customerIds.size());

        Integer count = 0;
        for (Id cId : customerIds) {
            processCustomer(cId);
            count++;
        }
        System.debug('Done. Processed ' + count + ' customers.');
    }

    /* ================================================
       NORMALIZE
    ================================================ */
/* ================================================
   NORMALIZE - Fully Enhanced Version
================================================ */
private static String normalize(String s) {
    if (s == null) return '';

    s = s.toLowerCase();

   

    // =====================
    // CITY NAME CORRECTIONS
    // =====================
    s = s.replace('bengaluru',   'bangalore');
    s = s.replace('bangaluru',   'bangalore');
    s = s.replace('banglore',    'bangalore');
    s = s.replace('banglaore',   'bangalore');
    s = s.replace('bombay',      'mumbai');
    s = s.replace('mumabi',      'mumbai');
    s = s.replace('mombai',      'mumbai');
    s = s.replace('madras',      'chennai');
    s = s.replace('channai',     'chennai');
    s = s.replace('chenai',      'chennai');
    s = s.replace('calcutta',    'kolkata');
    s = s.replace('kolkatta',    'kolkata');
    s = s.replace('poona',       'pune');
    s = s.replace('puna',        'pune');
    s = s.replace('mangaluru',   'mangalore');
    s = s.replace('mangalure',   'mangalore');
    s = s.replace('gurugram',    'gurgaon');
    s = s.replace('gurgoan',     'gurgaon');
    s = s.replace('vizag',       'visakhapatnam');
    s = s.replace('vishakapatnam','visakhapatnam');
    s = s.replace('vishakhapatnam','visakhapatnam');
    s = s.replace('secundrabad', 'secunderabad');
    s = s.replace('secunderabad','secunderabad');
    s = s.replace('hydrabad',    'hyderabad');
    s = s.replace('hydrabad',    'hyderabad');
    s = s.replace('dilli',       'delhi');
    s = s.replace('new delhi',   'delhi');
    s = s.replace('noida',       'noida');
    s = s.replace('navi mumbai', 'navimumbai');
    s = s.replace('new bombay',  'navimumbai');

    // =====================
    // REMOVE STATE NAMES 
    // Prevents state name affecting similarity
    // =====================
    s = s.replace('andhra pradesh',  '');
    s = s.replace('andhra',          '');
    s = s.replace('karnataka',       '');
    s = s.replace('maharashtra',     '');
    s = s.replace('tamil nadu',      '');
    s = s.replace('tamilnadu',       '');
    s = s.replace('telangana',       '');
    s = s.replace('kerala',          '');
    s = s.replace('gujarat',         '');
    s = s.replace('rajasthan',       '');
    s = s.replace('west bengal',     '');
    s = s.replace('uttar pradesh',   '');
    s = s.replace('madhya pradesh',  '');
    s = s.replace('bihar',           '');
    s = s.replace('odisha',          '');
    s = s.replace('punjab',          '');
    s = s.replace('haryana',         '');
    s = s.replace('uttarakhand',     '');
    s = s.replace('jharkhand',       '');
    s = s.replace('chhattisgarh',    '');
    s = s.replace('himachal pradesh','');
    s = s.replace('dakshina kannada','');

    // =====================
    // FLOOR NUMBERS
    // Must do BEFORE ordinal replacements
    // =====================
    s = s.replace('ground floor',  'gf');
    s = s.replace('grd floor',     'gf');
    s = s.replace('gr floor',      'gf');
    s = s.replace('g floor',       'gf');
    s = s.replace('basement floor','bf');
    s = s.replace('1st floor',     '1floor');
    s = s.replace('2nd floor',     '2floor');
    s = s.replace('3rd floor',     '3floor');
    s = s.replace('4th floor',     '4floor');
    s = s.replace('5th floor',     '5floor');
    s = s.replace('6th floor',     '6floor');
    s = s.replace('7th floor',     '7floor');
    s = s.replace('first floor',   '1floor');
    s = s.replace('second floor',  '2floor');
    s = s.replace('third floor',   '3floor');
    s = s.replace('fourth floor',  '4floor');
    s = s.replace('fifth floor',   '5floor');
    s = s.replace('sixth floor',   '6floor');
    s = s.replace('seventh floor', '7floor');

    // =====================
    // ORDINAL CORRECTIONS
    // Must do AFTER floor numbers
    // =====================
    s = s.replace('2nf', '2');
    s = s.replace('2nd', '2');
    s = s.replace('1st', '1');
    s = s.replace('3rd', '3');
    s = s.replace('4th', '4');
    s = s.replace('5th', '5');
    s = s.replace('6th', '6');
    s = s.replace('7th', '7');
    s = s.replace('8th', '8');
    s = s.replace('9th', '9');
    s = s.replace('10th','10');
    s = s.replace('first',   '1');
    s = s.replace('second',  '2');
    s = s.replace('third',   '3');
    s = s.replace('fourth',  '4');
    s = s.replace('fifth',   '5');
    s = s.replace('sixth',   '6');
    s = s.replace('seventh', '7');
    s = s.replace('eighth',  '8');
    s = s.replace('ninth',   '9');
    s = s.replace('tenth',   '10');

    // =====================
    // ROAD / STREET TYPES
    // =====================
    s = s.replace('strt',       'street');
    s = s.replace('sreet',      'street');
    s = s.replace('steet',      'street');
    s = s.replace('str',        'street');
    s = s.replace('rd.',        'road');
    s = s.replace(' rd ',       ' road ');
    s = s.replace('ave.',       'avenue');
    s = s.replace('ave ',       'avenue ');
    s = s.replace('blvd',       'boulevard');
    s = s.replace('ln.',        'lane');
    s = s.replace(' ln ',       ' lane ');
    s = s.replace('marg',       'road');
    s = s.replace('path',       'road');
    s = s.replace('ngr.',       'nagar');
    s = s.replace(' ngr ',      ' nagar ');
    s = s.replace('ngr',        'nagar');
    s = s.replace('nagr',       'nagar');
    s = s.replace('byepass',    'bypass');
    s = s.replace('bye pass',   'bypass');
    s = s.replace('high way',   'highway');
    s = s.replace('hw',         'highway');

    // =====================
    // BUILDING / UNIT TYPES
    // =====================
    s = s.replace('flr',        'floor');
    s = s.replace('fl.',        'floor');
    s = s.replace('bldg.',      'building');
    s = s.replace('bldg',       'building');
    s = s.replace('bld',        'building');
    s = s.replace('blg',        'building');
    s = s.replace('buliding',   'building');
    s = s.replace('buidling',   'building');
    s = s.replace('buiding',    'building');
    s = s.replace('buildig',    'building');
    s = s.replace('bilding',    'building');
    s = s.replace('apratment',  'apartment');
    s = s.replace('aparment',   'apartment');
    s = s.replace('apartmnt',   'apartment');
    s = s.replace('appartment', 'apartment');
    s = s.replace('flat',       'apartment');
    s = s.replace('apt.',       'apartment');
    s = s.replace('apt',        'apartment');
    s = s.replace('appt',       'apartment');
    s = s.replace('unit',       'apartment');
    s = s.replace('house no',   'doorno');
    s = s.replace('house',      'doorno');
    s = s.replace('h.no.',      'doorno');
    s = s.replace('h.no',       'doorno');
    s = s.replace('h no',       'doorno');
    s = s.replace('hn.',        'doorno');
    s = s.replace(' hn ',       ' doorno ');
    s = s.replace('door no',    'doorno');
    s = s.replace('door no.',   'doorno');
    s = s.replace('d.no.',      'doorno');
    s = s.replace('d.no',       'doorno');
    s = s.replace('d no',       'doorno');
    s = s.replace('plot no.',   'plot');
    s = s.replace('plot no',    'plot');
    s = s.replace('plt.',       'plot');
    s = s.replace('plt',        'plot');
    s = s.replace('shop no.',   'shop');
    s = s.replace('shop no',    'shop');
    s = s.replace('shp.',       'shop');
    s = s.replace('shp',        'shop');
    s = s.replace('s.no.',      'shop');
    s = s.replace('s.no',       'shop');
    s = s.replace(' s no ',     ' shop ');
    s = s.replace('godown',     'warehouse');
    s = s.replace('godwon',     'warehouse');
    s = s.replace('ware house', 'warehouse');

    // =====================
    // LOCALITY ABBREVIATIONS
    // =====================
    s = s.replace('col.',       'colony');
    s = s.replace(' col ',      ' colony ');
    s = s.replace('clny',       'colony');
    s = s.replace('colny',      'colony');
    s = s.replace('coloney',    'colony');
    s = s.replace('colon',      'colony');
    s = s.replace('extn.',      'extension');
    s = s.replace('extn',       'extension');
    s = s.replace('ext.',       'extension');
    s = s.replace(' ext ',      ' extension ');
    s = s.replace('encl.',      'enclave');
    s = s.replace('encl',       'enclave');
    s = s.replace(' lt ',       ' layout ');
    s = s.replace('layot',      'layout');
    s = s.replace('sec.',       'sector');
    s = s.replace(' sec ',      ' sector ');
    s = s.replace('blk.',       'block');
    s = s.replace(' blk ',      ' block ');
    s = s.replace('ph.',        'phase');
    s = s.replace(' ph ',       ' phase ');
    s = s.replace('soc.',       'society');
    s = s.replace(' soc ',      ' society ');
    s = s.replace('socity',     'society');
    s = s.replace('soceity',    'society');
    s = s.replace('societey',   'society');
    s = s.replace('hsng',       'housing');
    s = s.replace('hsg',        'housing');
    s = s.replace('twp',        'township');
    s = s.replace('town ship',  'township');
    s = s.replace('resid',      'residency');
    s = s.replace('resi',       'residency');

    // =====================
    // LANDMARK ABBREVIATIONS
    // =====================
    s = s.replace('opp.',       'opposite');
    s = s.replace(' opp ',      ' opposite ');
    s = s.replace('nr.',        'near');
    s = s.replace(' nr ',       ' near ');
    s = s.replace('adj.',       'adjacent');
    s = s.replace(' adj ',      ' adjacent ');
    s = s.replace('beh.',       'behind');
    s = s.replace(' beh ',      ' behind ');
    s = s.replace('bside',      'beside');
    s = s.replace('b/s',        'beside');
    s = s.replace('jn.',        'junction');
    s = s.replace(' jn ',       ' junction ');
    s = s.replace('junc.',      'junction');
    s = s.replace('junc',       'junction');
    s = s.replace('x road',     'junction');
    s = s.replace('xrd',        'junction');
    s = s.replace('signal',     'signal');
    s = s.replace('sgnl',       'signal');
    s = s.replace('chowk',      'chowk');
    s = s.replace('chawk',      'chowk');
    s = s.replace('circle',     'circle');
    s = s.replace('crcl',       'circle');

    // =====================
    // MARKET / COMMERCIAL
    // =====================
    s = s.replace('mkt.',       'market');
    s = s.replace(' mkt ',      ' market ');
    s = s.replace('mrkt',       'market');
    s = s.replace('cmplx',      'complex');
    s = s.replace('cmpx',       'complex');
    s = s.replace('cmpl',       'complex');
    s = s.replace('cmpleks',    'complex');
    s = s.replace('plza',       'plaza');
    s = s.replace(' plz ',      ' plaza ');
    s = s.replace('ctr.',       'center');
    s = s.replace(' ctr ',      ' center ');
    s = s.replace('centre',     'center');
    s = s.replace('centr',      'center');
    s = s.replace('indl.',      'industrial');
    s = s.replace('indl',       'industrial');
    s = s.replace('inds.',      'industrial');
    s = s.replace(' ind ',      ' industrial ');
    s = s.replace('est.',       'estate');
    s = s.replace(' est ',      ' estate ');
    s = s.replace('corp.',      'corporation');
    s = s.replace('corp',       'corporation');

    // =====================
    // CROSS / MAIN ROADS
    // =====================
    s = s.replace(' cr ',       ' cross ');
    s = s.replace('crs.',       'cross');
    s = s.replace('crs',        'cross');
    s = s.replace('c r',        'cross');
    s = s.replace(' mn ',       ' main ');
    s = s.replace('mn road',    'main road');

    // =====================
    // SYMBOLS AND CONNECTORS
    // =====================
    s = s.replace('&',          'and');
    s = s.replace('w/',         'with');
    s = s.replace('c/o',        'care of');
    s = s.replace('s/o',        'son of');
    s = s.replace('d/o',        'daughter of');
    s = s.replace('w/o',        'wife of');
    s = s.replace('no.',        'no');
    s = s.replace(' # ',        ' no ');
    s = s.replace('#',          'no ');

    // =====================
    // REMOVE SPECIAL CHARS
    // =====================
    s = s.replaceAll('[^a-z0-9 ]', ' ');

    // =====================
    // REMOVE DUPLICATE CONSECUTIVE WORDS
    // Example: "bangalore bangalore" → "bangalore"
    // =====================
    List<String> words = s.split(' ');
    List<String> deduped = new List<String>();
    String prevWord = '';
    for (String w : words) {
        if (w != '' && w != prevWord) {
            deduped.add(w);
            prevWord = w;
        }
    }
    s = String.join(deduped, ' ');

    // =====================
    // COLLAPSE SPACES
    // =====================
    s = s.replaceAll('\\s+', ' ').trim();

    return s;
}

    /* ================================================
       JACCARD SIMILARITY
    ================================================ */
    private static Decimal tokenSimilarity(String a, String b) {
        Set<String> setA = new Set<String>();
        Set<String> setB = new Set<String>();

        for (String s : a.split(' '))
            if (s != '') setA.add(s);

        for (String s : b.split(' '))
            if (s != '') setB.add(s);

        Set<String> intersection = new Set<String>();
        intersection.addAll(setA);
        intersection.retainAll(setB);

        Integer unionSize = setA.size() + setB.size() - intersection.size();
        if (unionSize == 0) return 0;

        return Decimal.valueOf(intersection.size()) /
               Decimal.valueOf(unionSize);
    }

}