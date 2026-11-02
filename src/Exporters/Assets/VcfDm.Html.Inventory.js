    const dm = name => rows(snapshot.Inventory || {}, name);
    const dmCategories = [
      ['vInfo','VMs and templates','Compute'],['vCPU','CPU configuration','Compute'],['vMemory','Memory configuration','Compute'],
      ['vDisk','Virtual disks','Storage'],['vPartition','Guest partitions and disk mapping','Storage'],['vSCSI','SCSI controllers','Storage'],
      ['vNetwork','VM network adapters','Network'],['vFloppy','Floppy devices','Compute'],['vCD','CD/DVD devices','Compute'],
      ['vSnapshot','Snapshots','Storage'],['vTools','VMware Tools','Compute'],['vRP','Resource pools','Compute'],
      ['vCluster','Clusters','Infrastructure'],['vHost','Hosts','Infrastructure'],['vTLShost','Host TLS profiles','Infrastructure'],
      ['vHBA','Host bus adapters','Storage'],['vNIC','Physical NICs','Network'],['vSwitch','Standard switches','Network'],
      ['vPort','Standard port groups','Network'],['dvSwitch','Distributed switches','Network'],['dvPort','Distributed port groups','Network'],
      ['vSC_VMK','VMkernel adapters','Network'],['vDatastore','Datastores','Storage'],['vZombieFiles','Unreferenced file candidates','Storage'],
      ['vLicense','Licensing','Infrastructure'],['vHealth','Alarm history (14 days)','Infrastructure']
    ];
    // XLSX is an OOXML ZIP package. All parts are generated locally, without dependencies.
    const dmZipBytes = files => {
      const encode = new TextEncoder(); const output=[]; const central=[]; let offset=0; let centralSize=0;
      const crc32 = data => {let crc=0xffffffff;for(const byte of data){crc^=byte;for(let bit=0;bit<8;bit++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}return (crc^0xffffffff)>>>0;};
      for(const file of files){
        const name=encode.encode(file.name),data=encode.encode(file.text),crc=crc32(data);
        const local=new Uint8Array(30+name.length);const lv=new DataView(local.buffer);
        lv.setUint32(0,0x04034b50,true);lv.setUint16(4,20,true);lv.setUint16(6,0x800,true);lv.setUint16(12,33,true);lv.setUint32(14,crc,true);lv.setUint32(18,data.length,true);lv.setUint32(22,data.length,true);lv.setUint16(26,name.length,true);local.set(name,30);
        const directory=new Uint8Array(46+name.length);const dv=new DataView(directory.buffer);
        dv.setUint32(0,0x02014b50,true);dv.setUint16(4,20,true);dv.setUint16(6,20,true);dv.setUint16(8,0x800,true);dv.setUint16(14,33,true);dv.setUint32(16,crc,true);dv.setUint32(20,data.length,true);dv.setUint32(24,data.length,true);dv.setUint16(28,name.length,true);dv.setUint32(42,offset,true);directory.set(name,46);
        output.push(local,data);central.push(directory);offset+=local.length+data.length;centralSize+=directory.length;
      }
      const end=new Uint8Array(22);const ev=new DataView(end.buffer);ev.setUint32(0,0x06054b50,true);ev.setUint16(8,files.length,true);ev.setUint16(10,files.length,true);ev.setUint32(12,centralSize,true);ev.setUint32(16,offset,true);
      const result=new Uint8Array(offset+centralSize+22);let cursor=0;for(const chunk of [...output,...central,end]){result.set(chunk,cursor);cursor+=chunk.length;}return result;
    };
    const dmExcelXml = value => String(value??'').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffe\uffff]/g,'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&apos;');
    const dmExcelColumn = index => {let result='';for(let n=index+1;n>0;n=Math.floor((n-1)/26))result=String.fromCharCode(65+(n-1)%26)+result;return result;};
    const dmWorkbookBytes = sheets => {
      if(!sheets.length)throw new Error('The workbook must contain at least one worksheet.');
      const names=new Set();
      const normalized=sheets.map((sheet,index)=>{
        const base=String(sheet.name||'Sheet'+(index+1)).replace(/[\\/?*\[\]:]/g,'-').replace(/^'+|'+$/g,'').slice(0,31)||'Sheet';let name=base,counter=1;
        while(names.has(name.toLowerCase())){const suffix='-'+(++counter);name=base.slice(0,31-suffix.length)+suffix;}names.add(name.toLowerCase());
        const columns=sheet.columns||[...new Set(sheet.rows.flatMap(row=>Object.keys(row||{})))];
        if(columns.length>16384||sheet.rows.length>1048575)throw new Error('The selection exceeds the Excel worksheet row or column limit.');
        return {...sheet,name,columns};
      });
      const declaration='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
      const mainNs='http://schemas.openxmlformats.org/spreadsheetml/2006/main';
      const relNs='http://schemas.openxmlformats.org/package/2006/relationships';
      const documentRelNs='http://schemas.openxmlformats.org/officeDocument/2006/relationships';
      const files=[
        {name:'[Content_Types].xml',text:declaration+'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'+normalized.map((_,index)=>'<Override PartName="/xl/worksheets/sheet'+(index+1)+'.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>').join('')+'</Types>'},
        {name:'_rels/.rels',text:declaration+'<Relationships xmlns="'+relNs+'"><Relationship Id="rId1" Type="'+documentRelNs+'/officeDocument" Target="xl/workbook.xml"/></Relationships>'},
        {name:'xl/workbook.xml',text:declaration+'<workbook xmlns="'+mainNs+'" xmlns:r="'+documentRelNs+'"><sheets>'+normalized.map((sheet,index)=>'<sheet name="'+dmExcelXml(sheet.name)+'" sheetId="'+(index+1)+'" r:id="rId'+(index+1)+'"/>').join('')+'</sheets></workbook>'},
        {name:'xl/_rels/workbook.xml.rels',text:declaration+'<Relationships xmlns="'+relNs+'">'+normalized.map((_,index)=>'<Relationship Id="rId'+(index+1)+'" Type="'+documentRelNs+'/worksheet" Target="worksheets/sheet'+(index+1)+'.xml"/>').join('')+'<Relationship Id="rId'+(normalized.length+1)+'" Type="'+documentRelNs+'/styles" Target="styles.xml"/></Relationships>'},
        {name:'xl/styles.xml',text:declaration+'<styleSheet xmlns="'+mainNs+'"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'}
      ];
      const cell=(value,ref,header=false)=>{
        const style=header?' s="1"':'';
        if(typeof value==='number'&&Number.isFinite(value))return '<c r="'+ref+'"'+style+'><v>'+value+'</v></c>';
        if(typeof value==='boolean')return '<c r="'+ref+'" t="b"'+style+'><v>'+(value?1:0)+'</v></c>';
        const string=value==null?'':typeof value==='object'?JSON.stringify(value):String(value);
        if(string.length>32767)throw new Error('A selected cell exceeds Excel’s 32,767-character limit.');
        // Inline text preserves names beginning with =, +, - or @ without creating formulas.
        return '<c r="'+ref+'" t="inlineStr"'+style+'><is><t xml:space="preserve">'+dmExcelXml(string)+'</t></is></c>';
      };
      normalized.forEach((sheet,index)=>{
        const columns=sheet.columns;const last=dmExcelColumn(Math.max(0,columns.length-1))+(sheet.rows.length+1);
        const header='<row r="1">'+columns.map((column,i)=>cell(column,dmExcelColumn(i)+'1',true)).join('')+'</row>';
        const data=sheet.rows.map((row,i)=>'<row r="'+(i+2)+'">'+columns.map((column,j)=>cell(get(row,column),dmExcelColumn(j)+(i+2))).join('')+'</row>').join('');
        files.push({name:'xl/worksheets/sheet'+(index+1)+'.xml',text:declaration+'<worksheet xmlns="'+mainNs+'"><dimension ref="A1:'+last+'"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols>'+columns.map((_,i)=>'<col min="'+(i+1)+'" max="'+(i+1)+'" width="24" customWidth="1"/>').join('')+'</cols><sheetData>'+header+data+'</sheetData>'+(columns.length?'<autoFilter ref="A1:'+last+'"/>':'')+'</worksheet>'});
      });
      return dmZipBytes(files);
    };
    const downloadExcel = (sheets,name) => {
      try{
        const blob=new Blob([dmWorkbookBytes(sheets)],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'}),url=URL.createObjectURL(blob),link=document.createElement('a');link.href=url;link.download='VCFExport-'+filenamePart(name)+'.xlsx';document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
      }catch(error){window.alert('Excel export failed: '+error.message);}
    };
    const dmColumns = input => [...new Set(input.flatMap(row=>Object.keys(row||{})))];
    const dmStatusRows = ds('VCF_CollectionStatus').filter(row=>String(get(row,'CollectorName','')).startsWith('Inventory.'));
    const dmSummary=document.getElementById('detailed-summary');
    card(dmSummary,'Inventory categories',dmCategories.length);
    card(dmSummary,'Detailed rows',dmCategories.reduce((sum,[name])=>sum+dm(name).length,0));
    card(dmSummary,'Successful collectors',dmStatusRows.filter(row=>get(row,'Status')==='SUCCESS').length+' / '+dmStatusRows.length);
    card(dmSummary,'Captured fields',dmCategories.reduce((sum,[name])=>sum+dmColumns(dm(name)).length,0));
    const hasInventoryCapture=dmStatusRows.length>0||dmCategories.some(([name])=>dm(name).length>0);
    document.getElementById('detailed-provenance').textContent=hasInventoryCapture?'26 inventory categories · captured configuration':'Detailed inventory was not captured in this snapshot. Run a fresh collection to include it.';
    const dmPicker=document.getElementById('detailed-category');
    for(const category of ['Compute','Infrastructure','Network','Storage']){
      const group=document.createElement('optgroup');group.label=category;
      dmCategories.filter(item=>item[2]===category).forEach(([name,label])=>group.append(new Option(label+' / '+name+' ('+dm(name).length+')',name)));dmPicker.append(group);
    }
    const dmOpenRow = (row,name) => {
      const detail=document.getElementById('detailed-detail');detail.textContent='';
      const title=String(first(row,['Name','Host','VM','ResourcePool','FilePath','AlarmName'],name));
      renderKv(detail,title+' · '+name,Object.keys(row).map(key=>[key,get(row,key)]));
      if(appUiReady)appDecorateDetail(detail,row,name);
      const source=cfgSource(row);const ref=cfgExactRef('vm',source,get(row,'VMId'))||cfgExactRef('host',source,get(row,'HostId'));
      if(ref){const action=make('button','button primary','Open '+ref.subtype+' relationships');action.type='button';action.addEventListener('click',()=>{cfgSelectRef(ref);document.querySelector('nav [data-view="virtual"]').click();});detail.prepend(action);}
      detail.scrollIntoView({block:'nearest',behavior:'smooth'});
    };
    const dmShowCategory = () => {
      const name=dmPicker.value;const input=dm(name);const statuses=dmStatusRows.filter(row=>get(row,'CollectorName')==='Inventory.'+name);
      const banner=document.getElementById('detailed-status');banner.textContent='';
      banner.className='banner'+(statuses.some(row=>get(row,'Status')!=='SUCCESS')?' partial':'');
      banner.append(make('strong','',dmCategories.find(item=>item[0]===name)?.[1]||name),document.createTextNode(' · '+input.length+' rows · '+dmColumns(input).length+' fields'));
      for(const status of statuses)banner.append(make('div','footnote',get(status,'SourceSystemFqdn')+' · '+get(status,'Status')+(get(status,'ErrorSummary')?' · '+get(status,'ErrorSummary'):'')));
      if(!statuses.length)banner.append(make('div','footnote','No collection status is present for this inventory category.'));
      const columns=dmColumns(input).filter(key=>!['SnapshotId','CollectedUTC','InventoryDataset','InventoryRowId','VI SDK Server','VI SDK UUID'].includes(key));
      new DataGrid(document.getElementById('detailed-grid'),input,'Inventory-'+name,{pageSize:50,defaultColumns:columns.slice(0,10),onRowClick:row=>dmOpenRow(row,name)});
      const detail=document.getElementById('detailed-detail');detail.textContent='';detail.append(make('h3','','Row details'),make('p','','Select an inventory row to see every collected field.'));
    };
    document.getElementById('detailed-download').addEventListener('click',()=>{
      const sheets=[],manifest=[];
      for(const [name,label] of dmCategories){const input=dm(name),columns=dmColumns(input);const status=dmStatusRows.filter(row=>get(row,'CollectorName')==='Inventory.'+name).map(row=>get(row,'SourceSystemFqdn')+': '+get(row,'Status')).join('; ')||'NOT_CAPTURED';sheets.push({name,rows:input.length?input:[{CollectionStatus:status,Note:'No inventory rows in this snapshot.'}],columns:input.length?columns:['CollectionStatus','Note']});manifest.push({Dataset:name,Description:label,Rows:input.length,Fields:columns.length,Status:status});}
      sheets.push({name:'Manifest',rows:manifest,columns:['Dataset','Description','Rows','Fields','Status']});
      downloadExcel(sheets,snapshot.SnapshotId+'-Inventory');
    });
    dmPicker.addEventListener('change',dmShowCategory);dmShowCategory();
    window.vcfDmInventory = Object.freeze({categories:dmCategories,zipBytes:dmZipBytes});
