    // Object relationship index used by both Virtual Configuration and World View.
    const cfgSource = row => String(first(row,['Source vCenter','SourceSystemFqdn','SourceSystemId'],'')).trim().toLowerCase();
    const cfgSplitIds = value => Array.isArray(value) ? value.map(String).filter(Boolean) : String(value||'').split(';').map(item=>item.trim()).filter(Boolean);
    const cfgSameSource = (left,right) => { const a=typeof left==='string'?left:cfgSource(left);const b=typeof right==='string'?right:cfgSource(right);return Boolean(a&&b&&a===b); };
    const cfgLabel = (row,fields,fallback) => first(row,fields,fallback);
    const cfgId = (row,fields,fallback) => first(row,fields,fallback);
    const cfgMakeRef = (type,dataset,row,index,idFields,labelFields,subtype=null) => {
      const source=cfgSource(row);const id=String(cfgId(row,idFields,stableId(row,'vSphere-'+dataset,index)));
      return {type,dataset,row,index,id,source,label:String(cfgLabel(row,labelFields,id)),subtype:subtype||type,key:type+'|'+source+'|'+id};
    };
    const cfgVmRefs=vs('vInfo').map((row,index)=>cfgMakeRef('vm','vInfo',row,index,['VMId','VCF Object Id'],['Name','VM'],'Virtual machine'));
    const cfgHostRefs=vs('vHost').map((row,index)=>cfgMakeRef('host','vHost',row,index,['HostId','VCF Object Id'],['Name','Host'],'Host'));
    const cfgClusterRefs=vs('vCluster').map((row,index)=>cfgMakeRef('cluster','vCluster',row,index,['ClusterId','VCF Object Id'],['Name','ClusterName'],'Cluster'));
    const cfgDatastoreRefs=vs('vDatastore').map((row,index)=>cfgMakeRef('datastore','vDatastore',row,index,['DatastoreId','VCF Object Id'],['Name'],'Datastore'));
    const cfgResourceRefs=vs('vResourcePools').map((row,index)=>cfgMakeRef('resource-pool','vResourcePools',row,index,['ResourcePoolId','VCF Object Id'],['Name'],'Resource pool'));
    const cfgNetworkRefs=[
      ...vs('dvSwitches').map((row,index)=>cfgMakeRef('network','dvSwitches',row,index,['VDSwitchId','VCF Object Id'],['Name'],'Distributed switch')),
      ...vs('dvPorts').map((row,index)=>cfgMakeRef('network','dvPorts',row,index,['PortgroupId','VCF Object Id'],['Name'],'Distributed port group')),
      ...vs('vSwitch').map((row,index)=>cfgMakeRef('network','vSwitch',row,index,['SwitchId','VCF Object Id'],['Name'],'Standard switch')),
      ...vs('vPort').map((row,index)=>cfgMakeRef('network','vPort',row,index,['PortgroupId','VCF Object Id'],['Name'],'Standard port group'))
    ];
    const cfgSets=new Map([
      ['vm',{label:'Virtual machines',singular:'Virtual machine',refs:cfgVmRefs}],
      ['host',{label:'Hosts',singular:'Host',refs:cfgHostRefs}],
      ['cluster',{label:'Clusters',singular:'Cluster',refs:cfgClusterRefs}],
      ['datastore',{label:'Datastores',singular:'Datastore',refs:cfgDatastoreRefs}],
      ['network',{label:'Networks and switches',singular:'Network object',refs:cfgNetworkRefs}],
      ['resource-pool',{label:'Resource pools',singular:'Resource pool',refs:cfgResourceRefs}]
    ]);
    const cfgRefs=[...cfgVmRefs,...cfgHostRefs,...cfgClusterRefs,...cfgDatastoreRefs,...cfgNetworkRefs,...cfgResourceRefs];
    const cfgRefByKey=new Map(cfgRefs.map(ref=>[ref.key,ref]));
    const cfgExactRef=(type,source,id) => {
      if(!id)return null;const matches=(cfgSets.get(type)?.refs||[]).filter(ref=>ref.id===String(id)&&(!source||ref.source===source));return matches.length===1?matches[0]:null;
    };
    const cfgUniqueLabelRef=(type,source,label) => {
      if(!label)return null;const wanted=String(label).toLowerCase();const matches=(cfgSets.get(type)?.refs||[]).filter(ref=>(!source||ref.source===source)&&ref.label.toLowerCase()===wanted);return matches.length===1?matches[0]:null;
    };
    const cfgEntityRows=(ref,dataset,idField,nameFields) => {
      const input=vs(dataset);const exact=input.filter(row=>cfgSameSource(ref.source,cfgSource(row))&&String(get(row,idField,''))===ref.id);
      if(exact.length)return {rows:exact,confidence:'authoritative'};
      const idAvailable=input.some(row=>get(row,idField)!==null&&get(row,idField)!=='');
      if(idAvailable)return {rows:[],confidence:'unavailable'};
      const sameNameRefs=(cfgSets.get(ref.type)?.refs||[]).filter(item=>item.source===ref.source&&item.label.toLowerCase()===ref.label.toLowerCase());
      if(sameNameRefs.length!==1)return {rows:[],confidence:'unavailable'};
      const fallback=input.filter(row=>cfgSameSource(ref.source,cfgSource(row))&&nameFields.some(field=>String(get(row,field,'')).toLowerCase()===ref.label.toLowerCase()));
      return {rows:fallback,confidence:fallback.length?'correlated':'unavailable'};
    };
    const cfgRelationNotice=(confidence,description) => {
      const note=make('div','relationship-note '+(confidence==='authoritative'?'':confidence));
      note.textContent=confidence==='authoritative'?'Linked by native vSphere object ID.':confidence==='correlated'?'Older snapshot: uniquely correlated by source vCenter and object name.':'No unambiguous relationship was captured for '+description+'.';
      return note;
    };
    const cfgOpenRawButton=(dataset,query) => {const button=make('button','button','Open raw '+dataset);button.type='button';button.addEventListener('click',()=>openInventoryRecord(dataset,query));return button;};
    const cfgCompactTable=(input,dataset,query) => {
      const fragment=document.createDocumentFragment();const wrap=make('div','compact-wrap');
      if(!input.length){wrap.append(make('div','empty','No rows collected.'));fragment.append(wrap);return fragment;}
      const columns=[...new Set(input.flatMap(row=>Object.keys(row||{})))];if(input.length===1){const list=make('dl','config-properties');columns.forEach(column=>list.append(make('dt','',column),make('dd','',get(input[0],column,''))));wrap.append(list);fragment.append(wrap);const footer=make('div','compact-footer');footer.append(make('span','','1 record · '+columns.length+' fields'),cfgOpenRawButton(dataset,query));fragment.append(footer);return fragment;}const table=make('table','compact-table');const head=document.createElement('thead');const header=document.createElement('tr');columns.forEach(column=>header.append(make('th','',column)));head.append(header);table.append(head);const body=document.createElement('tbody');
      input.slice(0,200).forEach(row=>{const tr=document.createElement('tr');columns.forEach(column=>{const td=make('td','',get(row,column,''));td.title=text(get(row,column,''));tr.append(td);});body.append(tr);});table.append(body);wrap.append(table);fragment.append(wrap);
      const footer=make('div','compact-footer');footer.append(make('span','',input.length>200?'Showing 200 of '+input.length+' rows':input.length+' row'+(input.length===1?'':'s')),cfgOpenRawButton(dataset,query));fragment.append(footer);return fragment;
    };
    const cfgSection=(container,title,dataset,result,query,open=false) => {
      const details=make('details','dossier-section');details.open=open;details.append(make('summary','',title+' ('+result.rows.length+')'));
      if(result.confidence!=='authoritative'&&result.rows.length)details.append(cfgRelationNotice(result.confidence,title));
      details.append(cfgCompactTable(result.rows,dataset,query));container.append(details);
    };
    const cfgRelatedLink=(container,ref,prefix='') => {if(!ref)return;const button=make('button','',prefix+ref.label);button.type='button';button.addEventListener('click',()=>cfgSelectRef(ref));container.append(button);};
    const cfgRefsFromIds=(type,source,ids) => cfgSplitIds(ids).map(id=>cfgExactRef(type,source,id)).filter(Boolean);
    const cfgVmChildren=[
      ['CPU','vCPU','VMId',['VM']],['Memory','vMemory','VMId',['VM']],['Virtual disks','vDisk','VMId',['VM']],['Guest partitions','vPartition','VMId',['VM']],['SCSI controllers','vSCSI','VMId',['VM']],['Network adapters','vNetwork','VMId',['VM']],['Floppy devices','vFloppy','VMId',['VM']],['CD/DVD devices','vCD','VMId',['VM']],['Snapshots','vSnapshot','VMId',['VM']],['VMware Tools','vTools','VMId',['VM']]
    ];
    const cfgHostChildren=[
      ['TLS identity','vTLShosts','HostId',['Host']],['Host bus adapters','vHBA','HostId',['Host']],['Physical NICs','vNIC','HostId',['Host']],['Standard switches','vSwitch','HostId',['Host']],['Standard port groups','vPort','HostId',['Host']],['VMkernel adapters','vSC_VMK','HostId',['Host']]
    ];
    const cfgDossier=document.getElementById('config-dossier');let cfgSelectedRef=null;
    const cfgPropertySection=(container,ref) => {const result={rows:[ref.row],confidence:'authoritative'};cfgSection(container,'Collected properties',ref.dataset,result,ref.id,true);};
    const cfgAddRelationshipHeading=(container,links,confidence='authoritative') => {
      if(!links.length)return;container.append(cfgRelationNotice(confidence,'related objects'));const linkBox=make('div','relationship-links');links.forEach(item=>cfgRelatedLink(linkBox,item.ref,item.prefix||''));container.append(linkBox);
    };
    const cfgRenderDossier = ref => {
      cfgDossier.textContent='';const heading=make('div','config-heading');const titleBox=document.createElement('div');titleBox.append(make('h3','',ref.label),make('div','footnote',ref.source||'Source not captured'));const identity=make('div','object-heading');if(appUiReady)identity.append(appObjectIcon(ref));identity.append(titleBox);heading.append(identity,make('span','type-badge',ref.subtype));cfgDossier.append(heading);
      const actions=make('div','action-row');actions.append(cfgOpenRawButton(ref.dataset,ref.id));if(['vm','host','cluster'].includes(ref.type)){const worldButton=make('button','button primary','Locate in World View');worldButton.type='button';worldButton.addEventListener('click',()=>worldLocateConfigRef(ref));actions.append(worldButton);}cfgDossier.append(actions);
      const links=[];
      if(ref.type==='vm'){
        const hostRef=cfgExactRef('host',ref.source,get(ref.row,'HostId'));const clusterRef=cfgExactRef('cluster',ref.source,get(ref.row,'ClusterId'));const poolRef=cfgExactRef('resource-pool',ref.source,get(ref.row,'ResourcePoolId'));
        if(clusterRef)links.push({ref:clusterRef,prefix:'Cluster: '});if(hostRef)links.push({ref:hostRef,prefix:'Host: '});if(poolRef)links.push({ref:poolRef,prefix:'Resource pool: '});cfgRefsFromIds('datastore',ref.source,get(ref.row,'DatastoreIds')).forEach(item=>links.push({ref:item,prefix:'Datastore: '}));
      }else if(ref.type==='host'){
        const clusterRef=cfgExactRef('cluster',ref.source,get(ref.row,'ClusterId'));if(clusterRef)links.push({ref:clusterRef,prefix:'Cluster: '});cfgVmRefs.filter(item=>item.source===ref.source&&String(get(item.row,'HostId',''))===ref.id).forEach(item=>links.push({ref:item,prefix:'VM: '}));cfgRefsFromIds('datastore',ref.source,get(ref.row,'DatastoreIds')).forEach(item=>links.push({ref:item,prefix:'Datastore: '}));
      }else if(ref.type==='cluster'){
        cfgHostRefs.filter(item=>item.source===ref.source&&String(get(item.row,'ClusterId',''))===ref.id).forEach(item=>links.push({ref:item,prefix:'Host: '}));cfgVmRefs.filter(item=>item.source===ref.source&&String(get(item.row,'ClusterId',''))===ref.id).forEach(item=>links.push({ref:item,prefix:'VM: '}));cfgRefsFromIds('datastore',ref.source,get(ref.row,'DatastoreIds')).forEach(item=>links.push({ref:item,prefix:'Datastore: '}));cfgResourceRefs.filter(item=>item.source===ref.source&&String(get(item.row,'OwnerId',''))===ref.id).forEach(item=>links.push({ref:item,prefix:'Resource pool: '}));
      }else if(ref.type==='datastore'){
        cfgRefsFromIds('host',ref.source,get(ref.row,'HostIds')).forEach(item=>links.push({ref:item,prefix:'Host: '}));cfgRefsFromIds('vm',ref.source,get(ref.row,'VmIds')).forEach(item=>links.push({ref:item,prefix:'VM: '}));
      }else if(ref.type==='resource-pool'){
        const owner=cfgExactRef('cluster',ref.source,get(ref.row,'OwnerId'));if(owner)links.push({ref:owner,prefix:'Owner: '});cfgRefsFromIds('vm',ref.source,get(ref.row,'VmIds')).forEach(item=>links.push({ref:item,prefix:'VM: '}));
      }else if(ref.type==='network'){
        if(ref.dataset==='dvSwitches')cfgNetworkRefs.filter(item=>item.dataset==='dvPorts'&&item.source===ref.source&&String(get(item.row,'VDSwitchId',''))===ref.id).forEach(item=>links.push({ref:item,prefix:'Port group: '}));
        if(ref.dataset==='dvPorts'){const parent=cfgExactRef('network',ref.source,get(ref.row,'VDSwitchId'));if(parent)links.push({ref:parent,prefix:'Switch: '});}
      }
      cfgAddRelationshipHeading(cfgDossier,links);
      if(appUiReady)cfgDossier.append(appConfigFacts(ref));
      cfgPropertySection(cfgDossier,ref);
      // Detailed inventory stays attached to the same native object identity.
      const detailTables=ref.type==='vm'?['vInfo','vCPU','vMemory','vDisk','vPartition','vSCSI','vNetwork','vFloppy','vCD','vSnapshot','vTools']:ref.type==='host'?['vHost','vTLShost','vHBA','vNIC','vSwitch','vPort','vSC_VMK']:ref.type==='cluster'?['vCluster']:ref.type==='datastore'?['vDatastore','vZombieFiles']:ref.type==='resource-pool'?['vRP']:ref.dataset==='dvSwitches'?['dvSwitch']:ref.dataset==='dvPorts'?['dvPort']:[];
      for(const dataset of detailTables){
        const input=rows(snapshot.Inventory||{},dataset);const idField=ref.type==='vm'?'VMId':ref.type==='host'?'HostId':dataset==='vZombieFiles'?'DatastoreId':'NativeObjectId';
        const matches=input.filter(row=>cfgSameSource(ref.source,cfgSource(row))&&String(get(row,idField,''))===ref.id);
        if(matches.length){const section=make('details','dossier-section');section.append(make('summary','',dataset+' ('+matches.length+')'));section.addEventListener('toggle',()=>{if(section.open&&!section.dataset.loaded){section.dataset.loaded='true';const target=make('div');section.append(target);new DataGrid(target,matches,'Inventory-'+dataset+'-'+ref.id,{pageSize:20,defaultColumns:Object.keys(matches[0]).slice(0,8)});}});cfgDossier.append(section);}
      }
      if(ref.type==='vm')cfgVmChildren.forEach((item,index)=>{const result=cfgEntityRows(ref,item[1],item[2],item[3]);cfgSection(cfgDossier,item[0],item[1],result,ref.id,index<2);});
      if(ref.type==='host')cfgHostChildren.forEach((item,index)=>{const result=cfgEntityRows(ref,item[1],item[2],item[3]);cfgSection(cfgDossier,item[0],item[1],result,ref.id,index<2);});
      if(ref.type==='cluster'){
        const relatedHosts=cfgHostRefs.filter(item=>item.source===ref.source&&String(get(item.row,'ClusterId',''))===ref.id).map(item=>item.row);const relatedVms=cfgVmRefs.filter(item=>item.source===ref.source&&String(get(item.row,'ClusterId',''))===ref.id).map(item=>item.row);const relatedStores=cfgRefsFromIds('datastore',ref.source,get(ref.row,'DatastoreIds')).map(item=>item.row);const relatedPools=cfgResourceRefs.filter(item=>item.source===ref.source&&String(get(item.row,'OwnerId',''))===ref.id).map(item=>item.row);
        cfgSection(cfgDossier,'Hosts','vHost',{rows:relatedHosts,confidence:'authoritative'},ref.id,true);cfgSection(cfgDossier,'Virtual machines','vInfo',{rows:relatedVms,confidence:'authoritative'},ref.id);cfgSection(cfgDossier,'Datastores','vDatastore',{rows:relatedStores,confidence:'authoritative'},ref.id);cfgSection(cfgDossier,'Resource pools','vResourcePools',{rows:relatedPools,confidence:'authoritative'},ref.id);
      }
      if(ref.type==='datastore'){
        const relatedDisks=vs('vDisk').filter(row=>cfgSameSource(ref.source,cfgSource(row))&&String(get(row,'DatastoreId',''))===ref.id);const relatedVms=cfgRefsFromIds('vm',ref.source,get(ref.row,'VmIds')).map(item=>item.row);const relatedHosts=cfgRefsFromIds('host',ref.source,get(ref.row,'HostIds')).map(item=>item.row);
        cfgSection(cfgDossier,'Virtual disks','vDisk',{rows:relatedDisks,confidence:'authoritative'},ref.id,true);cfgSection(cfgDossier,'Virtual machines','vInfo',{rows:relatedVms,confidence:'authoritative'},ref.id);cfgSection(cfgDossier,'Hosts','vHost',{rows:relatedHosts,confidence:'authoritative'},ref.id);
      }
      if(ref.type==='resource-pool'){
        const relatedVms=cfgRefsFromIds('vm',ref.source,get(ref.row,'VmIds')).map(item=>item.row);cfgSection(cfgDossier,'Virtual machines','vInfo',{rows:relatedVms,confidence:'authoritative'},ref.id,true);
      }
      if(ref.type==='network'){
        const names=new Set([ref.id,ref.label,String(get(ref.row,'PortgroupId','')),String(get(ref.row,'Name',''))].filter(Boolean));const vmNics=vs('vNetwork').filter(row=>cfgSameSource(ref.source,cfgSource(row))&&[get(row,'NetworkId'),get(row,'Network')].some(value=>names.has(String(value||''))));const vmks=vs('vSC_VMK').filter(row=>cfgSameSource(ref.source,cfgSource(row))&&[get(row,'DvPortgroupKey'),get(row,'Portgroup')].some(value=>names.has(String(value||''))));cfgSection(cfgDossier,'Connected VM adapters','vNetwork',{rows:vmNics,confidence:'authoritative'},ref.id,true);cfgSection(cfgDossier,'Connected VMkernel adapters','vSC_VMK',{rows:vmks,confidence:'authoritative'},ref.id);
      }
    };
    const cfgTypeSelect=document.getElementById('config-type');cfgSets.forEach((set,key)=>cfgTypeSelect.append(new Option(set.label+' ('+set.refs.length+')',key)));const cfgSearch=document.getElementById('config-search');const cfgList=document.getElementById('config-list');
    const cfgRenderList=()=>{cfgList.textContent='';const key=cfgTypeSelect.value||'vm';const set=cfgSets.get(key);const query=cfgSearch.value.trim().toLowerCase();const filtered=set.refs.filter(ref=>!query||[ref.label,ref.id,ref.source,ref.subtype,...Object.values(ref.row||{}).map(text)].join('\u0000').toLowerCase().includes(query));cfgList.append(make('div','config-list-summary',filtered.length+' matching / '+set.refs.length+' total '+set.label.toLowerCase()+(filtered.length>250?' · refine search to see more':'')));filtered.slice(0,250).forEach(ref=>{const button=make('button',cfgSelectedRef&&cfgSelectedRef.key===ref.key?'selected':'');button.type='button';if(appUiReady)button.append(appObjectIcon(ref));const labels=make('span','object-labels');labels.append(make('span','item-title',ref.label),make('span','item-meta',ref.subtype+' · '+(ref.source||'Source unknown')));button.append(labels);button.addEventListener('click',()=>cfgSelectRef(ref));cfgList.append(button);});if(!filtered.length)cfgList.append(make('div','config-empty','No matching objects.'));};
    function cfgSelectRef(ref){cfgSelectedRef=ref;cfgTypeSelect.value=ref.type;cfgRenderList();cfgRenderDossier(ref);}
    cfgTypeSelect.addEventListener('change',()=>{cfgSelectedRef=null;cfgRenderList();cfgDossier.textContent='';cfgDossier.append(make('div','config-empty','Select an object to view its configuration.'));});cfgSearch.addEventListener('input',cfgRenderList);document.getElementById('config-clear').addEventListener('click',()=>{cfgSearch.value='';cfgRenderList();cfgSearch.focus();});cfgRenderList();

