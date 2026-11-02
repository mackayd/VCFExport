Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Core\VcfDm.Security.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'VcfDm.Json.psm1') -ErrorAction Stop

function Get-VcfDmHtmlPropertyValue {
    param($InputObject, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-VcfDmHtmlJson {
    param([Parameter(Mandatory)] $Snapshot)

    $safeSnapshot = Remove-VcfDmSecretFields -InputObject $Snapshot
    $json = $safeSnapshot | ConvertTo-Json -Depth 100 -Compress
    if (Test-VcfDmForbiddenContent -Text $json) {
        throw 'HTML export was blocked because forbidden secret test content was detected.'
    }

    # The snapshot is placed in an inert application/json script element. Escaping
    # markup-significant characters prevents inventory text from terminating it.
    return $json.Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e').Replace(
        [string][char]0x2028,
        '\u2028'
    ).Replace([string][char]0x2029, '\u2029')
}

function Get-VcfDmHtmlAsset {
    param([Parameter(Mandatory)] [string] $Name)

    $path = Join-Path $PSScriptRoot "Assets\$Name"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required HTML report asset '$Name' was not found."
    }
    return [System.IO.File]::ReadAllText($path)
}

function Get-VcfDmHtmlBrandLogoDataUri {
    $assetName = 'Branding\vcfexport-logo-icon.png'
    $path = Join-Path $PSScriptRoot "Assets\$assetName"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required VCFexport branding asset '$assetName' was not found at '$path'. Restore it from the repository's src/Exporters/Assets/Branding directory and regenerate the report."
    }
    return 'data:image/png;base64,' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path))
}

function Get-VcfDmHtmlTemplate {
    return @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; font-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
  <title>__REPORT_TITLE__</title>
  <style>
    __APP_CSS__
    __WORLD_VIEW_CSS__
    __INFRA_CSS__
  </style>
</head>
<body data-generated-utc="__GENERATED_UTC__">
  <header class="topbar"><div class="app-brand"><img class="app-mark" src="__BRAND_LOGO_DATA_URI__" alt="" aria-hidden="true" width="621" height="287"><div class="app-brand-text"><h1>VCFexport</h1><div class="subtitle">Cloud Foundation infrastructure intelligence</div></div></div><div class="app-capture"><span id="app-capture-time" class="capture-meta"></span><span id="header-status" class="status-pill status-info">Loading snapshot</span></div></header>
  <div class="shell">
    <nav aria-label="Report sections">
      <span class="nav-caption">ESTATE WORKSPACE</span>
      <button type="button" data-view="overview" aria-current="page">Overview</button>
      <button type="button" data-view="world">World View</button>
      <button type="button" data-view="explorer">Infrastructure Explorer</button>
      <button type="button" data-view="virtual">Virtual Configuration</button>
      <button type="button" data-view="detailed">Detailed Inventory</button>
      <button type="button" data-view="lifecycle">Lifecycle / BOM</button>
      <button type="button" data-view="findings">Findings</button>
      <button type="button" data-view="inventory">Raw Inventory</button>
      <button type="button" data-view="collection">Collection Status</button>
      <div class="nav-footer">Offline inventory report<br>Configuration captured at a point in time.</div>
    </nav>
    <main>
      <section id="view-overview" class="view active" aria-labelledby="overview-title"><h2 id="overview-title">Overview</h2><p class="lede">A concise deployment, lifecycle, provenance, and collection-confidence summary. Missing data remains unknown rather than being inferred healthy.</p><div id="overview-banner"></div><div id="overview-cards" class="cards"></div><div class="split"><div id="overview-provenance" class="panel"></div><div id="overview-versions" class="panel"></div></div></section>
      __WORLD_VIEW_MARKUP__
      __INVENTORY_MARKUP__
      __INFRA_MARKUP__
      <section id="view-lifecycle" class="view" aria-labelledby="lifecycle-title"><h2 id="lifecycle-title">Lifecycle / BOM</h2><div id="lifecycle-context" class="cards"></div><div class="panel"><h3>Component bill of materials</h3><div id="bom-grid"></div></div><div class="panel"><h3>Upgrade paths</h3><div id="upgrade-grid"></div></div></section>
      <section id="view-findings" class="view" aria-labelledby="findings-title"><h2 id="findings-title">Findings</h2><p class="lede">Derived, evidence-backed conditions. Report defaults are identified by rule ID and do not claim to be VMware policy.</p><div id="finding-summary" class="cards"></div><div id="findings-grid"></div></section>
      <section id="view-inventory" class="view" aria-labelledby="inventory-title"><h2 id="inventory-title">Raw Inventory</h2><div class="dataset-picker"><div class="control"><label for="dataset-select">Dataset</label><select id="dataset-select"></select></div></div><div id="inventory-grid"></div></section>
      <section id="view-collection" class="view" aria-labelledby="collection-title"><h2 id="collection-title">Collection Status</h2><div id="collection-banner"></div><div id="collection-grid"></div></section>
    </main>
  </div>
  <script id="snapshot-data" type="application/json">__SNAPSHOT_JSON__</script>
  <script>
  'use strict';
  (() => {
    let appUiReady=false;
    const snapshot = JSON.parse(document.getElementById('snapshot-data').textContent);
    const get = (obj, key, fallback = null) => obj && Object.prototype.hasOwnProperty.call(obj, key) && obj[key] !== null && obj[key] !== undefined ? obj[key] : fallback;
    const rows = (container, name) => { const value = container && container[name]; return Array.isArray(value) ? value : value == null ? [] : [value]; };
    const ds = name => rows(snapshot.Datasets || {}, name);
    const vs = name => rows(snapshot.VSphere || {}, name);
    const text = value => value === null || value === undefined || value === '' ? '\u2014' : typeof value === 'object' ? JSON.stringify(value) : String(value);
    const first = (row, names, fallback = null) => { for (const name of names) { const value = get(row, name); if (value !== null && value !== '') return value; } return fallback; };
    const make = (tag, className, value) => { const node = document.createElement(tag); if (className) node.className = className; if (value !== undefined) node.textContent = text(value); return node; };
    const statusClass = value => { const s = String(value || '').toUpperCase(); if (s.includes('COMPLETE') && !s.includes('PARTIAL')) return 'status-success'; if (s.includes('PARTIAL') || s.includes('WARNING')) return 'status-partial'; if (s.includes('FAIL') || s.includes('ERROR') || s.includes('UNREACHABLE')) return 'status-failed'; return 'status-info'; };
    const idFieldsByDataset = {'VCF Instance':['VCFInstanceId','VCF Instance Id'],'VCF_Instances':['VCFInstanceId'],'Domain':['DomainId'],'VCF_Domains':['DomainId'],'Cluster':['ClusterId'],'VCF_Clusters':['ClusterId'],'Host':['HostId'],'VCF_Hosts':['HostId'],'vCenter':['VCenterId'],'VCF_vCenters':['VCenterId'],'SDDC Manager':['SDDCManagerId'],'VCF_SDDCManagers':['SDDCManagerId'],'Management Component':['ComponentId'],'VCF_ManagementComponents':['ComponentId'],'NSX Cluster':['NSXClusterId'],'VCF_NSXClusters':['NSXClusterId'],'Edge Cluster':['EdgeClusterId'],'VCF_EdgeClusters':['EdgeClusterId'],'VCF_NetworkPools':['NetworkPoolId'],'VCF_ComponentDrift':['ComponentId','ResourceId'],'VCF_Certificates':['CertificateId','ResourceId'],'VCF_Compliance':['AuditId'],'Findings':['FindingId'],'Collection-Status':['CollectorName']};
    const nativeIdFields = ['VCF Object Id','FindingId','AuditId','ResourceId','CertificateId','LicenseId','ComponentId','BundleId','ReleaseId','NetworkPoolId','EdgeClusterId','NSXClusterId','SDDCManagerId','VCenterId','HostId','ClusterId','DomainId'];
    const stableId = (row, dataset, index) => { if(get(row,'InventoryRowId'))return dataset+':'+row.InventoryRowId; const candidates=idFieldsByDataset[dataset]||nativeIdFields; for (const key of candidates) { const value = get(row, key); if (value) return dataset + ':' + key + ':' + value; } return dataset + ':source:' + text(first(row,['SourceSystemId','SourceSystemFqdn','Source vCenter'],'unknown')) + ':row:' + index; };
    const filenamePart = value => String(value || 'Export').replace(/[<>:"/\\|?*\u0000-\u001f]/g,'-').replace(/\s+/g,'-').replace(/-+/g,'-').replace(/^[-.]+|[-.]+$/g,'').slice(0,100) || 'Export';
    const csvValue = value => { let output = value === null || value === undefined ? '' : typeof value === 'object' ? JSON.stringify(value) : String(value); if (/^[\s\u0000-\u001f]*[=+\-@]/.test(output)) output = "'" + output; return '"' + output.replace(/"/g,'""') + '"'; };
    const csvText = (exportRows, columns) => '\uFEFF' + [columns.map(csvValue).join(','), ...exportRows.map(row => columns.map(column => csvValue(get(row,column,''))).join(','))].join('\r\n');
    const downloadCsv = (exportRows, columns, name) => { const blob = new Blob([csvText(exportRows, columns)], {type:'text/csv;charset=utf-8'}); const url = URL.createObjectURL(blob); const link = document.createElement('a'); link.href=url; link.download='VCFExport-' + filenamePart(name) + '-' + new Date().toISOString().replace(/[-:]/g,'').slice(0,15) + '.csv'; document.body.appendChild(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000); };
    window.vcfDmCsv = Object.freeze({csvValue,csvText,filenamePart});

    class DataGrid {
      constructor(container, inputRows, name, options = {}) { this.container=container; this.rows=Array.isArray(inputRows)?inputRows:[]; this.name=name; this.options=options; this.search=''; this.filters={instance:'',domain:'',source:''}; this.sortColumn=''; this.sortDirection=1; this.page=1; this.pageSize=Number(options.pageSize||100); this.selected=new Set(); this.columns=this.getColumns(); this.visible=new Set(options.defaultColumns||this.columns); this.build(); this.render(); }
      getColumns(){ const found=new Set(); for(const row of this.rows){ if(row && typeof row==='object') Object.keys(row).forEach(key=>found.add(key)); } return [...found]; }
      pick(row,names){ const value=first(row,names,'');return (value===null||value===undefined?'':String(value)).toLowerCase(); }
      unique(names){ return [...new Set(this.rows.map(row=>this.pick(row,names)).filter(Boolean))].sort(); }
      build(){ this.container.textContent=''; this.root=make('div','grid'); const controls=make('div','grid-controls'); const addSelect=(label,key,names)=>{ const values=this.unique(names);if(!values.length)return;const wrap=make('div','control'); wrap.append(make('label','',label)); const select=document.createElement('select'); select.setAttribute('aria-label',label); select.append(new Option('All','')); values.forEach(value=>select.append(new Option(value,value))); select.addEventListener('change',()=>{this.filters[key]=select.value;this.page=1;this.render();}); wrap.append(select); controls.append(wrap); };
        const searchWrap=make('div','control'); searchWrap.append(make('label','','Search')); const search=document.createElement('input'); this.searchInput=search; search.type='search'; search.placeholder='Search rows'; search.setAttribute('aria-label','Search table rows'); search.addEventListener('input',()=>{this.search=search.value.toLowerCase();this.page=1;this.render();}); searchWrap.append(search); controls.append(searchWrap);
        addSelect('VCF instance','instance',['VCFInstanceName','VCFInstanceId','VCF Instance','VCF Instance Id']); addSelect('Domain','domain',['DomainName','DomainId','VCF Domain','VCF Domain Id']); addSelect('Source','source',['SourceSystemFqdn','SourceSystemId','Source vCenter']);
        const columnDetails=make('details','column-menu'); const summary=make('summary','button','Columns'); columnDetails.append(summary); const columnOptions=make('div','column-options'); this.columns.forEach(column=>{const label=make('label');const box=document.createElement('input');box.type='checkbox';box.checked=this.visible.has(column);box.addEventListener('change',()=>{box.checked?this.visible.add(column):this.visible.delete(column);this.render();});label.append(box,document.createTextNode(' '+column));columnOptions.append(label);});columnDetails.append(columnOptions);controls.append(columnDetails);
        const button=(label,handler,primary=false)=>{const b=make('button','button'+(primary?' primary':''),label);b.type='button';b.addEventListener('click',handler);controls.append(b);};
        const excel=this.name.startsWith('Inventory-');const suffix=excel?' (Excel)':'';const exportRows=(input,columns,name)=>excel?downloadExcel([{name:this.name,rows:input,columns}],name):downloadCsv(input,columns,name);
        button('Export Current View'+suffix,()=>exportRows(this.filteredSorted(),this.visibleColumns(),this.name+'-Current'),true); button('Export All Rows'+suffix,()=>exportRows(this.rows,this.columns,this.name+'-All')); button('Export Selected Rows'+suffix,()=>{const selected=this.rows.filter((row,index)=>this.selected.has(stableId(row,this.name,index)));if(!selected.length){window.alert('Select one or more rows first.');return;}exportRows(selected,this.visibleColumns(),this.name+'-Selected');});
        this.root.append(controls); this.wrap=make('div','table-wrap'); this.table=document.createElement('table'); this.table.setAttribute('aria-label',this.name+' data'); this.wrap.append(this.table); this.root.append(this.wrap); this.footer=make('div','grid-footer'); this.root.append(this.footer); this.container.append(this.root); }
      visibleColumns(){ return this.columns.filter(column=>this.visible.has(column)); }
      filteredSorted(){ const visible=this.visibleColumns(); let output=this.rows.filter(row=>{ if(this.filters.instance && this.pick(row,['VCFInstanceName','VCFInstanceId','VCF Instance','VCF Instance Id'])!==this.filters.instance)return false;if(this.filters.domain && this.pick(row,['DomainName','DomainId','VCF Domain','VCF Domain Id'])!==this.filters.domain)return false;if(this.filters.source && this.pick(row,['SourceSystemFqdn','SourceSystemId','Source vCenter'])!==this.filters.source)return false;if(this.search){const haystack=this.columns.map(column=>text(get(row,column,'')).toLowerCase()).join('\u0000');if(!haystack.includes(this.search))return false;}return true;}); if(this.sortColumn){const column=this.sortColumn;const direction=this.sortDirection;output=[...output].sort((a,b)=>{const av=get(a,column,'');const bv=get(b,column,'');const an=Number(av),bn=Number(bv);if(av!==''&&bv!==''&&Number.isFinite(an)&&Number.isFinite(bn))return(an-bn)*direction;return String(av).localeCompare(String(bv),undefined,{numeric:true,sensitivity:'base'})*direction;});} return output; }
      render(){
        const columns=this.visibleColumns(); const filtered=this.filteredSorted(); const pageCount=Math.max(1,Math.ceil(filtered.length/this.pageSize));
        this.page=Math.min(this.page,pageCount); const pageRows=filtered.slice((this.page-1)*this.pageSize,this.page*this.pageSize); this.table.textContent='';
        if(!columns.length||!pageRows.length){
          this.wrap.textContent='';
          const message=!this.rows.length?'No rows were collected for this dataset.':!columns.length?'Choose at least one visible column.':'No rows match the active view.';
          this.wrap.append(make('div','empty',message));
        }else{
          this.wrap.textContent=''; this.wrap.append(this.table);
          const head=document.createElement('thead'); const hr=document.createElement('tr'); const selectHead=document.createElement('th'); const selectPage=document.createElement('input');
          selectPage.type='checkbox'; selectPage.setAttribute('aria-label','Select visible page rows'); selectPage.addEventListener('change',()=>{pageRows.forEach(row=>{const originalIndex=this.rows.indexOf(row);const id=stableId(row,this.name,originalIndex);selectPage.checked?this.selected.add(id):this.selected.delete(id);});this.render();}); selectHead.append(selectPage); hr.append(selectHead);
          columns.forEach(column=>{const th=document.createElement('th');const b=make('button','',column+(this.sortColumn===column?(this.sortDirection===1?' \u25b2':' \u25bc'):''));b.type='button';b.addEventListener('click',()=>{if(this.sortColumn===column)this.sortDirection*=-1;else{this.sortColumn=column;this.sortDirection=1;}this.page=1;this.render();});th.append(b);hr.append(th);});
          head.append(hr); this.table.append(head); const body=document.createElement('tbody');
          pageRows.forEach(row=>{const originalIndex=this.rows.indexOf(row);const id=stableId(row,this.name,originalIndex);const tr=document.createElement('tr');if(typeof this.options.onRowClick==='function'){tr.classList.add('row-action');tr.tabIndex=0;const openRow=event=>{if(event.target.closest('input,button,a'))return;this.options.onRowClick(row);};tr.addEventListener('click',openRow);tr.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();this.options.onRowClick(row);}});}const selectCell=document.createElement('td');const check=document.createElement('input');check.type='checkbox';check.checked=this.selected.has(id);check.setAttribute('aria-label','Select row');check.addEventListener('change',()=>{check.checked?this.selected.add(id):this.selected.delete(id);});selectCell.append(check);tr.append(selectCell);columns.forEach(column=>{const value=get(row,column,'');const td=make('td');if(/^(Status|Severity|CollectionStatus|RiskState|ExpirationStatus|OverallStatus|PowerState|ConnectionState)$/i.test(column)&&value!=='')td.append(make('span','cell-status '+appStatusTone(value),value));else td.textContent=text(value);td.title=text(value);tr.append(td);});body.append(tr);});
          this.table.append(body);
        }
        this.footer.textContent=''; this.footer.append(make('span','',filtered.length+' filtered / '+this.rows.length+' total rows')); const pager=make('div','pager'); const previous=make('button','button','Previous'); previous.type='button'; previous.disabled=this.page<=1; previous.addEventListener('click',()=>{this.page--;this.render();}); const next=make('button','button','Next'); next.type='button'; next.disabled=this.page>=pageCount; next.addEventListener('click',()=>{this.page++;this.render();}); pager.append(previous,make('span','','Page '+this.page+' of '+pageCount),next); this.footer.append(pager);
      }
    }

    const card=(container,label,value,subtext)=>{const item=make('div','card');item.append(make('div','label',label),make('div','value',value));if(subtext)item.append(make('div','footnote',subtext));container.append(item);};
    const renderKv=(container,title,entries)=>{container.textContent='';container.append(make('h3','',title));const grid=make('div','kv');entries.forEach(([key,value])=>grid.append(make('div','key',key),make('div','',value)));container.append(grid);};
    const reportStatus=String(snapshot.ReportStatus||'UNKNOWN'); const headerStatus=document.getElementById('header-status');headerStatus.textContent=reportStatus;headerStatus.className='status-pill '+statusClass(reportStatus);
    const summary=ds('VCF_Summary')[0]||{}; const lifecycle=snapshot.LifecycleKnowledge||{}; const vms=vs('vInfo'); const datastores=vs('vDatastore'); const capacity=datastores.reduce((total,row)=>total+Number(get(row,'CapacityGiB',0)||0),0); const free=datastores.reduce((total,row)=>total+Number(get(row,'FreeGiB',0)||0),0);
    const banner=document.getElementById('overview-banner');const bannerBox=make('div','banner '+(reportStatus.includes('PARTIAL')?'partial':reportStatus.includes('COMPLETE')?'':'failed'));bannerBox.append(make('strong','',reportStatus),document.createTextNode(reportStatus.includes('PARTIAL')?' \u2014 review Collection Status before relying on missing datasets.':' \u2014 collection confidence is based on the status rows captured in this snapshot.'));if(reportStatus.includes('PARTIAL')){const review=make('button','button','Review Collection Status');review.type='button';review.addEventListener('click',()=>document.querySelector('nav [data-view="collection"]').click());bannerBox.append(document.createTextNode(' '),review);}banner.append(bannerBox);
    const overviewCards=document.getElementById('overview-cards'); card(overviewCards,'VCF instance',first(summary,['VCFInstanceName'],first(ds('VCF_Instances')[0]||{},['VCFInstanceName'],'Unknown')));card(overviewCards,'VCF release',first(summary,['SystemRelease'],get(lifecycle,'DeployedVersion','Unknown')));card(overviewCards,'Domains',ds('VCF_Domains').length);card(overviewCards,'Clusters',ds('VCF_Clusters').length);card(overviewCards,'Hosts',ds('VCF_Hosts').length);card(overviewCards,'Virtual machines',vms.length);card(overviewCards,'Datastore capacity',capacity?capacity.toFixed(1)+' GiB':'Unknown',capacity?free.toFixed(1)+' GiB free':null);card(overviewCards,'Certificate risks',first(summary,['CertificateRiskCount'],'Unknown'));card(overviewCards,'Component drift',ds('VCF_ComponentDrift').filter(row=>String(get(row,'DriftDetected','')).toLowerCase()==='true'||String(get(row,'VersionDriftStatus','')).includes('DRIFT')).length);card(overviewCards,'Compliance rows',ds('VCF_Compliance').length);
    renderKv(document.getElementById('overview-provenance'),'Report provenance',[['Snapshot ID',snapshot.SnapshotId],['Collected UTC',snapshot.CollectedUTC],['Schema version',snapshot.SchemaVersion],['Collector version',snapshot.CollectorVersion],['Collection mode',snapshot.CollectionMode],['Lifecycle scope',snapshot.LifecycleKnowledgeScope],['Reference metadata',get(lifecycle,'ReferenceMetadataFileName','Not supplied')],['Reference SHA-256',get(lifecycle,'ReferenceMetadataArchiveSha256','Not supplied')],['External latest status',get(lifecycle,'BroadcomCurrentLatestStatus','UNKNOWN')]]);
    const versionLines=[];const addDistribution=(label,input,key)=>{const counts=new Map();input.forEach(row=>{const value=text(get(row,key,'Unknown'));counts.set(value,(counts.get(value)||0)+1);});versionLines.push([label,[...counts.entries()].map(([v,c])=>v+' ('+c+')').join(', ')||'Not collected']);};addDistribution('SDDC Manager',ds('VCF_SDDCManagers'),'Version');addDistribution('vCenter',ds('VCF_vCenters'),'Version');addDistribution('ESXi',ds('VCF_Hosts'),'CurrentESXVersion');addDistribution('NSX',ds('VCF_NSXClusters'),'Version');renderKv(document.getElementById('overview-versions'),'Version distribution',versionLines);

    const labelFields={'VCF Instance':['VCFInstanceName','SDDCManagerFqdn'],'Domain':['DomainName'],'Cluster':['ClusterName'],'Host':['HostFqdn'],'vCenter':['VCenterFqdn','Fqdn'],'SDDC Manager':['SDDCManagerFqdn','Fqdn'],'Management Component':['ComponentFqdn','ComponentName','Name'],'NSX Cluster':['VipFqdn','NSXManagerFqdns','Name'],'Edge Cluster':['EdgeClusterName','Name'],'Virtual Machine':['Name','VM'],'Datastore':['Name'],'Certificate':['ResourceFqdn','ResourceName','Subject'],'Backup':['ResourceFqdn','SourceSystemFqdn','Name']}; const objectLabel=(row,type)=>first(row,labelFields[type]||['Name','Fqdn','VCFInstanceName'],type);

    const lifecycleCards=document.getElementById('lifecycle-context');card(lifecycleCards,'Live deployment',get(lifecycle,'DeployedVersion','Unknown'),'Observed from the captured VCF environment');card(lifecycleCards,'Local latest known',get(lifecycle,'LocalCatalogLatestKnownVersion','Unknown'),get(lifecycle,'LocalCatalogPublishedUTC','Publication time unavailable'));card(lifecycleCards,'Reference latest known',get(lifecycle,'ReferenceMetadataLatestKnownVersion','Not supplied'),get(lifecycle,'ReferenceMetadataPublishedUTC','Point-in-time metadata not supplied'));card(lifecycleCards,'Broadcom current latest',get(lifecycle,'BroadcomCurrentLatestStatus','UNKNOWN'),'Never inferred from local-only metadata');new DataGrid(document.getElementById('bom-grid'),ds('VCF_BOM'),'Lifecycle-BOM',{pageSize:50});new DataGrid(document.getElementById('upgrade-grid'),ds('VCF_UpgradePaths'),'Upgrade-Paths',{pageSize:50});

    const deriveFindings=()=>{const findings=[];let sequence=0;const add=(severity,category,row,source,field,summaryText,evidence,rule)=>findings.push({FindingId:'VCFDM-FINDING-'+String(++sequence).padStart(4,'0'),Severity:severity,Category:category,ObjectId:first(row,['VCF Object Id','ResourceId','ComponentId','HostId','ClusterId','DomainId','CollectorName'],'snapshot'),ObjectType:source,ObjectName:objectLabel(row,source),VCFInstanceId:first(row,['VCFInstanceId','VCF Instance Id']),DomainId:first(row,['DomainId','VCF Domain Id']),Summary:summaryText,Evidence:evidence,RuleId:rule,SourceDataset:source,SourceField:field});ds('VCF_CollectionStatus').filter(row=>['PARTIAL','NOT_AUTHORIZED','UNREACHABLE','COLLECTION_FAILED'].includes(String(get(row,'Status','')).toUpperCase())).forEach(row=>add('Critical','Collection',row,'VCF_CollectionStatus','Status','Collector did not complete successfully',text(get(row,'CollectorName'))+' = '+text(get(row,'Status'))+': '+text(get(row,'ErrorSummary')),'VCFDM-COLLECTION-FAILURE'));ds('VCF_Certificates').filter(row=>['EXPIRED','CRITICAL','WARNING'].includes(String(get(row,'RiskState','')).toUpperCase())).forEach(row=>add(String(get(row,'RiskState')).toUpperCase()==='WARNING'?'Warning':'Critical','Certificate',row,'VCF_Certificates','DaysRemaining','Certificate expiry requires attention',objectLabel(row,'Certificate')+' has '+text(get(row,'DaysRemaining'))+' days remaining','VCFDM-CERTIFICATE-EXPIRY'));ds('VCF_CredentialHealth').filter(row=>['EXPIRED','CRITICAL','WARNING'].includes(String(get(row,'ExpirationStatus','')).toUpperCase())).forEach(row=>add('Warning','Credential',row,'VCF_CredentialHealth','ExpirationStatus','Credential expiry requires attention',text(get(row,'ExpirationStatus')),'VCFDM-CREDENTIAL-EXPIRY'));ds('VCF_ComponentDrift').filter(row=>String(get(row,'DriftDetected','')).toLowerCase()==='true'||String(get(row,'DriftType','')).toUpperCase().includes('DRIFT')).forEach(row=>add('Warning','Lifecycle',row,'VCF_ComponentDrift','DriftDetected','Component drift detected',text(get(row,'DriftDetails')),'VCFDM-COMPONENT-DRIFT'));const catalogAge=Number(get(lifecycle,'LocalCatalogAgeDays',NaN));if(Number.isFinite(catalogAge)&&catalogAge>30)add('Warning','Lifecycle',lifecycle,'LifecycleKnowledge','LocalCatalogAgeDays','Local lifecycle metadata is older than the report default threshold',catalogAge+' days old; report threshold is 30 days and is not VMware policy','VCFDM-LIFECYCLE-STALE-30D');ds('VCF_Lifecycle').filter(row=>String(get(row,'UpgradeAvailable','')).toUpperCase()==='YES').forEach(row=>add('Info','Lifecycle',row,'VCF_Lifecycle','UpgradeAvailable','A newer release is represented by the recorded assessment source','Basis: '+text(get(row,'UpgradeAssessmentBasis'))+'; confidence: '+text(get(row,'AssessmentConfidence')),'VCFDM-NEWER-RELEASE-KNOWN'));ds('VCF_Backups').filter(row=>get(row,'BackupConfigured')===false||String(get(row,'BackupConfigured','')).toUpperCase()==='FALSE').forEach(row=>add('Warning','Backup',row,'VCF_Backups','BackupConfigured','Backup is reported as not configured',objectLabel(row,'Backup')+' reports BackupConfigured=false','VCFDM-BACKUP-NOT-CONFIGURED'));return findings.sort((a,b)=>({Critical:0,Warning:1,Info:2}[a.Severity]-({Critical:0,Warning:1,Info:2}[b.Severity])));};
    let openInventoryRecord=null;const findings=deriveFindings();const findingSummary=document.getElementById('finding-summary');['Critical','Warning','Info'].forEach(severity=>card(findingSummary,severity,findings.filter(row=>row.Severity===severity).length));new DataGrid(document.getElementById('findings-grid'),findings,'Findings',{pageSize:100,onRowClick:row=>{if(openInventoryRecord)openInventoryRecord(row.SourceDataset,row.ObjectId==='snapshot'?row.ObjectName:row.ObjectId);}});

    const inventorySets=[];Object.keys(snapshot.Datasets||{}).forEach(name=>inventorySets.push({label:'VCF / '+name,name,rows:ds(name)}));Object.keys(snapshot.VSphere||{}).forEach(name=>inventorySets.push({label:'vSphere / '+name,name:'vSphere-'+name,rows:vs(name)}));Object.keys(snapshot.Inventory||{}).forEach(name=>inventorySets.push({label:'Inventory / '+name,name:'Inventory-'+name,rows:rows(snapshot.Inventory,name)}));const selector=document.getElementById('dataset-select');inventorySets.forEach((item,index)=>selector.append(new Option(item.label+' ('+item.rows.length+')',String(index))));let inventoryGrid=null;const showDataset=()=>{const item=inventorySets[Number(selector.value||0)];const target=document.getElementById('inventory-grid');target.textContent='';inventoryGrid=item?new DataGrid(target,item.rows,item.name,{pageSize:100}):null;};openInventoryRecord=(dataset,query)=>{const index=inventorySets.findIndex(item=>item.name===dataset||item.name==='vSphere-'+dataset);if(index<0)return;selector.value=String(index);showDataset();document.querySelector('nav [data-view="inventory"]').click();if(query&&inventoryGrid){inventoryGrid.searchInput.value=String(query);inventoryGrid.search=String(query).toLowerCase();inventoryGrid.render();}};selector.addEventListener('change',showDataset);showDataset();
    __WORLD_VIEW_SCRIPT__
    __INVENTORY_SCRIPT__
    __INFRA_SCRIPT__
    const collectionBanner=document.getElementById('collection-banner');const statusRows=ds('VCF_CollectionStatus');const success=statusRows.filter(row=>String(get(row,'Status')).toUpperCase()==='SUCCESS').length;const expected=statusRows.filter(row=>['NOT_SUPPLIED','NOT_SUPPORTED','NOT_DEPLOYED','NOT_REQUESTED'].includes(String(get(row,'Status')).toUpperCase())).length;const failures=statusRows.length-success-expected;const collectionBox=make('div','banner '+(failures?'partial':''));collectionBox.append(make('strong','',success+' successful, '+expected+' expected unavailable/not supplied/not requested, '+failures+' failed or partial'));collectionBanner.append(collectionBox);new DataGrid(document.getElementById('collection-grid'),statusRows,'Collection-Status',{pageSize:100});
    document.querySelectorAll('nav [data-view]').forEach(button=>button.addEventListener('click',()=>{document.querySelectorAll('.view').forEach(view=>view.classList.remove('active'));document.querySelectorAll('nav [data-view]').forEach(item=>item.removeAttribute('aria-current'));document.getElementById('view-'+button.dataset.view).classList.add('active');button.setAttribute('aria-current','page');location.hash=button.dataset.view;}));const requested=location.hash.slice(1);const requestedButton=document.querySelector('nav [data-view="'+CSS.escape(requested)+'"]');if(requestedButton)requestedButton.click();
    __APP_SCRIPT__
  })();
  </script>
</body>
</html>
'@
}

function Export-VcfDmSnapshotHtml {
    [CmdletBinding(DefaultParameterSetName = 'Snapshot')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Snapshot')] $Snapshot,
        [Parameter(Mandatory, ParameterSetName = 'Path')] [ValidateNotNullOrEmpty()] [string] $SnapshotPath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path,
        [string] $Title
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $Snapshot = Import-VcfDmSnapshotJson -Path $SnapshotPath
    }
    $schemaVersion = Get-VcfDmHtmlPropertyValue -InputObject $Snapshot -Name 'SchemaVersion'
    $snapshotId = Get-VcfDmHtmlPropertyValue -InputObject $Snapshot -Name 'SnapshotId'
    if (-not $schemaVersion -or -not $snapshotId) {
        throw 'The supplied object is not a supported VCFExport snapshot.'
    }
    $Snapshot = ConvertTo-VcfDmCurrentSnapshot $Snapshot
    $json = ConvertTo-VcfDmHtmlJson -Snapshot $Snapshot
    $appCss = Get-VcfDmHtmlAsset -Name 'VcfDm.Html.App.css'
    $appScript = Get-VcfDmHtmlAsset -Name 'VcfDm.Html.App.js'
    $worldViewCss = (Get-VcfDmHtmlAsset -Name 'VcfDm.Html.WorldView.css') + "`n" + (Get-VcfDmHtmlAsset -Name 'VcfDm.Html.Configuration.css')
    $worldViewMarkup = (Get-VcfDmHtmlAsset -Name 'VcfDm.Html.WorldView.html') + "`n" + (Get-VcfDmHtmlAsset -Name 'VcfDm.Html.Configuration.html')
    $worldViewScript = (Get-VcfDmHtmlAsset -Name 'VcfDm.Html.Configuration.js') + "`n" + (Get-VcfDmHtmlAsset -Name 'VcfDm.Html.WorldView.js')
    $detailedMarkup = Get-VcfDmHtmlAsset -Name 'VcfDm.Html.Inventory.html'
    $detailedScript = Get-VcfDmHtmlAsset -Name 'VcfDm.Html.Inventory.js'
    $infraCss = Get-VcfDmHtmlAsset -Name 'VcfDm.Html.Infrastructure.css'
    $infraMarkup = Get-VcfDmHtmlAsset -Name 'VcfDm.Html.Infrastructure.html'
    $infraScript = Get-VcfDmHtmlAsset -Name 'VcfDm.Html.Infrastructure.js'
    $brandLogoDataUri = Get-VcfDmHtmlBrandLogoDataUri
    $reportTitle = if ($Title) { $Title } else { "VCFexport Explorer - $snapshotId" }
    $html = (Get-VcfDmHtmlTemplate).
        Replace('__REPORT_TITLE__', [System.Net.WebUtility]::HtmlEncode($reportTitle)).
        Replace('__BRAND_LOGO_DATA_URI__', $brandLogoDataUri).
        Replace('__GENERATED_UTC__', [datetime]::UtcNow.ToString('o')).
        Replace('__APP_CSS__', $appCss).
        Replace('__APP_SCRIPT__', $appScript).
        Replace('__WORLD_VIEW_CSS__', $worldViewCss).
        Replace('__WORLD_VIEW_MARKUP__', $worldViewMarkup).
        Replace('__WORLD_VIEW_SCRIPT__', $worldViewScript).
        Replace('__INVENTORY_MARKUP__', $detailedMarkup).
        Replace('__INVENTORY_SCRIPT__', $detailedScript).
        Replace('__INFRA_CSS__', $infraCss).
        Replace('__INFRA_MARKUP__', $infraMarkup).
        Replace('__INFRA_SCRIPT__', $infraScript).
        Replace('__SNAPSHOT_JSON__', $json)
    if (Test-VcfDmForbiddenContent -Text $html) {
        throw 'HTML export was blocked because forbidden secret test content was detected.'
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $html, [System.Text.UTF8Encoding]::new($false))
    return (Get-Item -LiteralPath $Path)
}

function New-VcfDmHtmlReport {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SnapshotPath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $OutputPath,
        [string] $Title
    )
    if ($PSCmdlet.ShouldProcess($OutputPath, 'Generate offline VCF HTML report')) {
        return Export-VcfDmSnapshotHtml -SnapshotPath $SnapshotPath -Path $OutputPath -Title $Title
    }
}

Export-ModuleMember -Function @('Export-VcfDmSnapshotHtml', 'New-VcfDmHtmlReport')
