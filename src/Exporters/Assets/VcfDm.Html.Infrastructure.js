    // The explorer shares World View's glyphs and attribute projections, with its own full inventory tree.
    const infraNodes=new Map(),infraRoots=[],infraOpen=new Set(),infraLimits=new Map();
    const infraTree=document.getElementById('infra-tree'),infraDetail=document.getElementById('infra-detail');
    const infraSearch=document.getElementById('infra-search'),infraType=document.getElementById('infra-type');
    let infraSelected=null,infraRelatedLimit=12;
    const infraAdd=(key,kind,label,row={},options={})=>{
      if(infraNodes.has(key))return infraNodes.get(key);
      const node={key,kind,label:String(label),row,source:cfgSource(row),children:[],records:[],ref:null,...options};
      if(options.dataset)node.records.push({label:options.dataset,row});infraNodes.set(key,node);return node;
    };
    const infraAttach=(parent,node)=>{if(parent&&parent.key!==node.key&&!node.parent){node.parent=parent.key;parent.children.push(node.key);}return node;};
    const infraBucket=(parent,name,label)=>infraAttach(parent,infraAdd(parent.key+'|group|'+name,'group',label,{}, {groupType:name}));
    const infraKind=ref=>ref.type==='network'?(ref.dataset==='dvSwitches'||ref.dataset==='vSwitch'?'switch':'network'):ref.type==='resource-pool'?'pool':ref.type==='vm'&&get(ref.row,'Template')===true?'template':ref.type;
    const infraFromRef=ref=>infraAdd('infra|'+ref.key,infraKind(ref),ref.label,ref.row,{ref,dataset:'vSphere / '+ref.dataset});
    const infraInstanceId=row=>String(first(row,['VCFInstanceId','VCF Instance Id'],''));
    const infraDomainId=row=>String(first(row,['DomainId','VCF Domain Id'],''));
    const infraScope=(instanceId,domainId)=>instanceId+'|'+domainId;
    const infraInstances=new Map(),infraDomains=new Map();
    ds('VCF_Instances').forEach((row,i)=>{const id=String(get(row,'VCFInstanceId','instance-'+i));const node=infraAdd('infra-instance|'+id,'instance',first(row,['VCFInstanceName','SDDCManagerFqdn'],'VCF instance'),row,{dataset:'VCF_Instances'});infraInstances.set(id,node);infraRoots.push(node.key);});
    if(!infraRoots.length&&(cfgRefs.length||ds('VCF_Domains').length)){
      const node=infraAdd('infra-instance|snapshot','instance','Captured infrastructure');infraInstances.set('snapshot',node);infraRoots.push(node.key);
    }
    const infraInstanceFor=row=>infraInstances.get(infraInstanceId(row))||infraNodes.get(infraRoots[0]);
    ds('VCF_Domains').forEach((row,i)=>{const id=String(get(row,'DomainId','domain-'+i)),parent=infraInstanceFor(row);if(!parent)return;const node=infraAttach(parent,infraAdd('infra-domain|'+infraScope(infraInstanceId(row),id),'domain',get(row,'DomainName','Workload domain'),row,{dataset:'VCF_Domains'}));infraDomains.set(infraScope(infraInstanceId(row),id),node);});
    const infraParentFor=row=>{
      const domain=infraDomains.get(infraScope(infraInstanceId(row),infraDomainId(row)));if(domain)return domain;
      const instance=infraInstanceFor(row);if(!instance)return null;
      if(!infraDomainId(row)&&get(row,'SourceSystemType')==='SDDC_MANAGER')return instance;
      if(infraDomainId(row)||cfgSource(row))return infraBucket(instance,'unassigned-'+(cfgSource(row)||infraDomainId(row)),'Unassigned · '+(cfgSource(row)||infraDomainId(row)));
      return instance;
    };
    const infraClusterMap=new Map(),infraSddcClusterMap=new Map(),infraHostMap=new Map();
    cfgClusterRefs.forEach(ref=>{const parent=infraParentFor(ref.row);if(parent){const node=infraAttach(infraBucket(parent,'compute','Compute clusters'),infraFromRef(ref));infraClusterMap.set(ref.source+'|'+ref.id,node);}});
    ds('VCF_Clusters').forEach((row,i)=>{
      const parent=infraParentFor(row);if(!parent)return;
      const matches=cfgClusterRefs.filter(ref=>infraInstanceId(ref.row)===infraInstanceId(row)&&infraDomainId(ref.row)===infraDomainId(row)&&ref.label===get(row,'ClusterName'));
      let node;if(matches.length===1){node=infraFromRef(matches[0]);node.records.push({label:'VCF_Clusters',row});node.vcfRow=row;node.linkNote='VCF and vSphere records correlated by instance, domain and unique cluster name.';}
      else node=infraAttach(infraBucket(parent,'compute','Compute clusters'),infraAdd('infra-vcf-cluster|'+infraScope(infraInstanceId(row),String(get(row,'ClusterId',i))),'cluster',get(row,'ClusterName','Cluster'),row,{dataset:'VCF_Clusters'}));
      infraSddcClusterMap.set(infraScope(infraInstanceId(row),String(get(row,'ClusterId'))),node);
    });
    cfgHostRefs.forEach(ref=>{const parent=infraClusterMap.get(ref.source+'|'+String(get(ref.row,'ClusterId')))||infraParentFor(ref.row);if(parent){const node=infraAttach(infraBucket(parent,'hosts','ESXi hosts'),infraFromRef(ref));infraHostMap.set(ref.source+'|'+ref.id,node);}});
    ds('VCF_Hosts').forEach((row,i)=>{
      const matches=cfgHostRefs.filter(ref=>infraInstanceId(ref.row)===infraInstanceId(row)&&infraDomainId(ref.row)===infraDomainId(row)&&ref.label.toLowerCase()===String(get(row,'HostFqdn','')).toLowerCase());
      if(matches.length===1){const node=infraFromRef(matches[0]);node.records.push({label:'VCF_Hosts',row});node.linkNote='VCF and vSphere records correlated by instance, domain and unique host FQDN.';return;}
      const parent=infraSddcClusterMap.get(infraScope(infraInstanceId(row),String(get(row,'ClusterId'))))||infraParentFor(row);if(parent)infraAttach(infraBucket(parent,'hosts','ESXi hosts'),infraAdd('infra-vcf-host|'+infraScope(infraInstanceId(row),String(get(row,'HostId',i))),'host',get(row,'HostFqdn','Host'),row,{dataset:'VCF_Hosts'}));
    });
    cfgVmRefs.forEach(ref=>{const parent=infraHostMap.get(ref.source+'|'+String(get(ref.row,'HostId')))||infraClusterMap.get(ref.source+'|'+String(get(ref.row,'ClusterId')))||infraParentFor(ref.row);if(parent)infraAttach(infraBucket(parent,'workloads','Workloads & templates'),infraFromRef(ref));});
    cfgDatastoreRefs.forEach(ref=>{const parent=infraParentFor(ref.row);if(parent)infraAttach(infraBucket(parent,'storage','Shared storage'),infraFromRef(ref));});
    cfgResourceRefs.forEach(ref=>{const parent=infraClusterMap.get(ref.source+'|'+String(get(ref.row,'OwnerId')))||infraParentFor(ref.row);if(parent)infraAttach(infraBucket(parent,'pools','Resource pools'),infraFromRef(ref));});
    cfgNetworkRefs.filter(ref=>ref.dataset==='dvSwitches'||ref.dataset==='vSwitch').forEach(ref=>{const parent=(ref.dataset==='vSwitch'&&infraHostMap.get(ref.source+'|'+String(get(ref.row,'HostId'))))||infraParentFor(ref.row);if(parent)infraAttach(infraBucket(parent,'network','Networks & switches'),infraFromRef(ref));});
    cfgNetworkRefs.filter(ref=>ref.dataset==='dvPorts'||ref.dataset==='vPort').forEach(ref=>{const switchRef=ref.dataset==='dvPorts'&&cfgExactRef('network',ref.source,get(ref.row,'VDSwitchId'));const parent=(switchRef&&infraFromRef(switchRef))||infraParentFor(ref.row);if(parent)infraAttach(parent.kind==='switch'?parent:infraBucket(parent,'network','Networks & switches'),infraFromRef(ref));});
    for(const [dataset,type,labels,ids] of [
      ['VCF_vCenters','vCenter',['VCenterFqdn','Fqdn'],['VCenterId']],['VCF_SDDCManagers','SDDC Manager',['SDDCManagerFqdn','Fqdn'],['SDDCManagerId']],
      ['VCF_NSXClusters','NSX cluster',['VipFqdn','Name'],['NSXClusterId']],['VCF_ManagementComponents','Management service',['ComponentFqdn','ComponentName','Name'],['ComponentId']],
      ['VCF_EdgeClusters','Edge cluster',['EdgeClusterName','Name'],['EdgeClusterId']],['VCF_NetworkPools','Network pool',['NetworkPoolName','Name'],['NetworkPoolId']]
    ])ds(dataset).forEach((row,i)=>{const parent=infraParentFor(row);if(parent)infraAttach(infraBucket(parent,'services','Management & VCF services'),infraAdd('infra-service|'+dataset+'|'+infraScope(infraInstanceId(row),String(first(row,ids,i))),'component',first(row,labels,type),row,{dataset,subtype:type}));});

    const infraRelations=new Map();
    const infraRelate=(a,b,label,reverse=label)=>{if(!a||!b||a.key===b.key)return;for(const [from,to,kind] of [[a,b,label],[b,a,reverse]]){if(!infraRelations.has(from.key))infraRelations.set(from.key,new Map());infraRelations.get(from.key).set(to.key,{node:to,label:kind});}};
    infraNodes.forEach(node=>{if(node.parent)infraRelate(infraNodes.get(node.parent),node,'Contains','Within');});
    cfgVmRefs.forEach(ref=>{
      const vm=infraFromRef(ref);cfgRefsFromIds('datastore',ref.source,get(ref.row,'DatastoreIds')).forEach(store=>infraRelate(vm,infraFromRef(store),'Stored on','Stores workload'));
      const pool=cfgExactRef('resource-pool',ref.source,get(ref.row,'ResourcePoolId'));if(pool)infraRelate(vm,infraFromRef(pool),'Allocated to','Allocates resources to');
      vs('vNetwork').filter(row=>cfgSource(row)===ref.source&&String(get(row,'VMId'))===ref.id).forEach(nic=>{const net=cfgExactRef('network',ref.source,get(nic,'NetworkId'));if(net)infraRelate(vm,infraFromRef(net),'Connected to','Connects workload');});
    });
    cfgHostRefs.forEach(ref=>cfgRefsFromIds('datastore',ref.source,get(ref.row,'DatastoreIds')).forEach(store=>infraRelate(infraFromRef(ref),infraFromRef(store),'Mounts datastore','Mounted by')));
    const infraTypeLabel=node=>node.subtype||({instance:'VCF instance',domain:'Workload domain',cluster:'Cluster',host:'ESXi host',vm:'Virtual machine',template:'VM template',datastore:'Datastore',switch:'Virtual switch',network:'Port group',pool:'Resource pool',component:'Management service',group:'Inventory group'}[node.kind]||node.kind);
    const infraState=node=>String(first(node.row,['Status','OverallStatus','LifecycleState','IsolationStatus','ConnectionState','PowerState'],''));
    const infraStateClass=value=>{const state=value.toLowerCase().replace(/[\s_]/g,'');return ['red','failed','error','disconnected','unreachable','inactive'].includes(state)?'bad':['yellow','warning','degraded','maintenance'].includes(state)?'warn':['green','success','active','connected','poweredon','stable','up','assigned'].includes(state)?'good':'';};
    const infraCount=node=>{if(node.count!==undefined)return node.count;node.count=node.children.reduce((sum,key)=>{const next=infraNodes.get(key);return sum+(next.kind==='group'?0:1)+infraCount(next);},0);return node.count;};
    infraNodes.forEach(node=>{infraCount(node);node.searchText=[node.label,infraTypeLabel(node),node.source,...node.records.flatMap(record=>Object.values(record.row).map(text))].join('\u0000').toLowerCase();if(['instance','domain','cluster'].includes(node.kind)||node.groupType==='compute'||node.groupType==='hosts')infraOpen.add(node.key);});
    const infraIcon=kind=>{const svg=worldSvgNode('svg',{viewBox:'0 0 64 74','class':'infra-icon','aria-hidden':'true'});svg.append(worldIcon(kind));return svg;};
    const infraLogicalParent=node=>{let parent=infraNodes.get(node.parent);while(parent?.kind==='group')parent=infraNodes.get(parent.parent);return parent;};
    const infraFacts=node=>{
      if(node.kind==='group')return [['Objects',node.count],['Category',node.label]];
      const facts=worldFactPairs(node).filter(([key])=>key!=='Related objects'&&(!['instance','domain'].includes(node.kind)||!['Hosts','Clusters'].includes(key)));
      if(node.kind==='instance'||node.kind==='domain'){
        const members=[];const visit=item=>item.children.forEach(key=>{const next=infraNodes.get(key);members.push(next);visit(next);});visit(node);
        for(const [label,kinds] of [['Clusters',['cluster']],['ESXi hosts',['host']],['Workloads',['vm','template']],['Datastores',['datastore']],['Networks & switches',['network','switch']]])if(!facts.some(([name])=>name===label))facts.push([label,members.filter(item=>kinds.includes(item.kind)).length]);
      }
      if(!facts.length)facts.push(['Related objects',infraRelations.get(node.key)?.size||0]);return facts.slice(0,8);
    };
    const infraRelated=node=>{
      const result=new Map();for(const relation of infraRelations.get(node.key)?.values()||[]){
        if(relation.node.kind==='group'){if(relation.label==='Within')continue;for(const key of relation.node.children){const next=infraNodes.get(key);if(next.key!==node.key&&next.kind!=='group')result.set(key,{node:next,label:relation.label});}}
        else result.set(relation.node.key,relation);
      }
      const parent=infraLogicalParent(node);if(parent)result.set(parent.key,{node:parent,label:'Within'});result.delete(node.key);return [...result.values()];
    };
    const infraButton=(label,handler,primary=false)=>{const button=make('button','infra-action'+(primary?' primary':''),label);button.type='button';button.addEventListener('click',handler);return button;};
    const infraProperties=(node,record)=>{
      const isIdentity=key=>/^(SnapshotId|CollectedUTC|CollectorVersion|SchemaVersion|SourceSystem|VCF Instance|VCF Domain|Source vCenter|CollectionWarning)/i.test(key)||/(Id|Ids|Uuid)$/i.test(key);
      const fields=Object.keys(record.row),sets=[['Configuration · '+record.label,fields.filter(key=>!isIdentity(key))],['Capture & identity · '+record.label,fields.filter(isIdentity)]];
      for(const [label,keys] of sets){if(!keys.length)continue;const section=make('details','infra-properties');section.open=label.startsWith('Configuration')&&keys.length<=16;section.append(make('summary','',label+' · '+keys.length+' fields'));const list=make('dl','infra-property-list');keys.forEach(key=>{list.append(make('dt','',key),make('dd','',get(record.row,key)));});section.append(list);infraDetail.append(section);}
    };
    const infraRenderDetail=node=>{
      infraDetail.textContent='';const path=[];let current=node;while(current){path.unshift(current);current=infraNodes.get(current.parent);}
      const breadcrumb=make('div','infra-breadcrumb');breadcrumb.setAttribute('aria-label','Object ancestry');path.filter(item=>item.kind!=='group').forEach((item,i)=>{if(i)breadcrumb.append(make('span','','›'));const button=make('button','',item.label);button.type='button';button.addEventListener('click',()=>infraSelect(item));breadcrumb.append(button);});infraDetail.append(breadcrumb);
      const hero=make('div','infra-hero');hero.append(infraIcon(node.kind));const heading=make('div','infra-hero-main');heading.append(make('span','infra-type-tag',infraTypeLabel(node)),make('h3','',node.label));const source=node.ref?.source||first(node.row,['SourceSystemFqdn','Source vCenter','VCFInstanceName']);if(source)heading.append(make('div','infra-subtitle',source));hero.append(heading);const state=infraState(node);hero.append(make('span','infra-status '+infraStateClass(state),state||'State not captured'));infraDetail.append(hero);
      const actions=make('div','infra-actions');
      if(node.ref){actions.append(infraButton('Locate in World View',()=>worldLocateConfigRef(node.ref),true),infraButton('Full virtual configuration',()=>{cfgSelectRef(node.ref);document.querySelector('nav [data-view="virtual"]').click();}));}
      else actions.append(infraButton('Open World View',()=>document.querySelector('nav [data-view="world"]').click(),true));
      if(node.records.length){const record=node.records[0],dataset=node.ref?node.ref.dataset:record.label;const id=node.ref?.id||first(node.row,['HostId','ClusterId','DomainId','VCenterId','ComponentId','VCFInstanceId'],node.label);actions.append(infraButton('Open inventory rows',()=>openInventoryRecord(dataset,id)));}infraDetail.append(actions);
      const facts=make('div','infra-attributes');infraFacts(node).forEach(([key,value])=>{const card=make('div','infra-attribute');card.append(make('span','',key),make('strong','',value));facts.append(card);});infraDetail.append(facts);
      if(node.linkNote)infraDetail.append(make('p','infra-note correlated',node.linkNote));
      const related=infraRelated(node),sectionHeading=make('div','infra-section-heading');sectionHeading.append(make('h4','','Related infrastructure'),make('span','',related.length+' objects'));infraDetail.append(sectionHeading);
      if(related.length){const grid=make('div','infra-related');related.slice(0,infraRelatedLimit).forEach(({node:next,label})=>{const button=make('button','infra-related-card');button.type='button';button.append(infraIcon(next.kind));const content=document.createElement('div');content.append(make('strong','',next.label),make('small','',label+' · '+infraTypeLabel(next)));button.append(content);button.addEventListener('click',()=>infraSelect(next));grid.append(button);});infraDetail.append(grid);if(related.length>infraRelatedLimit)infraDetail.append(infraButton('Show '+Math.min(24,related.length-infraRelatedLimit)+' more related objects',()=>{infraRelatedLimit+=24;infraRenderDetail(node);}));}
      else infraDetail.append(make('p','infra-note','No further relationships were captured for this object.'));
      if(node.records.length){const heading=make('div','infra-section-heading');heading.append(make('h4','','Collected configuration'),make('span','',node.records.length+' source'+(node.records.length===1?'':'s')));infraDetail.append(heading);node.records.forEach(record=>infraProperties(node,record));}
    };
    function infraSelect(node){infraSelected=node.key;infraRelatedLimit=12;infraSearch.value='';infraType.value='';let current=node,parent=infraNodes.get(node.parent);while(parent){infraOpen.add(parent.key);infraLimits.set(parent.key,Math.max(infraLimits.get(parent.key)||50,parent.children.indexOf(current.key)+1));current=parent;parent=infraNodes.get(parent.parent);}infraRenderTree();infraRenderDetail(node);infraDetail.scrollTop=0;}
    const infraRenderTree=()=>{
      infraTree.textContent='';const query=infraSearch.value.trim().toLowerCase(),type=infraType.value,filter=!!(query||type);const matches=new Set();
      infraNodes.forEach(node=>{if(node.kind!=='group'&&(!type||node.kind===type)&&(!query||node.searchText.includes(query)))matches.add(node.key);});
      const shown=new Set(matches);for(const key of matches){let parent=infraNodes.get(infraNodes.get(key).parent);while(parent){shown.add(parent.key);parent=infraNodes.get(parent.parent);}}
      document.getElementById('infra-match-count').textContent=matches.size+' '+(filter?'matching':'captured')+' objects';
      const render=node=>{
        const children=node.children.map(key=>infraNodes.get(key)).filter(next=>!filter||shown.has(next.key));const branch=children.length>0;const container=branch?make('details','infra-branch'):null;const row=make(branch?'summary':'button','infra-row '+node.kind+(infraSelected===node.key?' selected':''));
        if(!branch)row.type='button';row.setAttribute('data-infra-key',node.key);if(infraSelected===node.key)row.setAttribute('aria-current','true');row.append(make('span','infra-caret',branch?'›':''),infraIcon(node.kind));const labels=make('span','infra-row-text');labels.append(make('span','infra-row-name',node.label));if(node.kind!=='group')labels.append(make('span','infra-row-meta',infraTypeLabel(node)+(infraState(node)?' · '+infraState(node):'')));row.append(labels);if(node.count){const badge=make('span','infra-row-count',node.count);badge.title=node.count+' descendant objects';row.append(badge);}
        row.addEventListener('click',()=>{infraSelected=node.key;infraRelatedLimit=12;infraTree.querySelectorAll('.infra-row.selected').forEach(item=>{item.classList.remove('selected');item.removeAttribute('aria-current');});row.classList.add('selected');row.setAttribute('aria-current','true');infraRenderDetail(node);infraDetail.scrollTop=0;});
        if(!branch)return row;
        container.append(row);container.open=filter||infraOpen.has(node.key);let loaded=false;
        const load=()=>{if(loaded)return;loaded=true;const box=make('div','infra-children'),limit=infraLimits.get(node.key)||50;children.slice(0,limit).forEach(next=>box.append(render(next)));if(children.length>limit){const more=make('button','infra-show-more','Show '+Math.min(50,children.length-limit)+' more ('+(children.length-limit)+' remaining)');more.type='button';more.addEventListener('click',()=>{infraLimits.set(node.key,limit+50);infraRenderTree();});box.append(more);}container.append(box);};
        if(container.open)load();container.addEventListener('toggle',()=>{if(!container.isConnected)return;if(container.open){if(!filter)infraOpen.add(node.key);load();}else if(!filter)infraOpen.delete(node.key);});return container;
      };
      infraRoots.map(key=>infraNodes.get(key)).filter(node=>!filter||shown.has(node.key)).forEach(node=>infraTree.append(render(node)));
      if(!infraTree.childElementCount)infraTree.append(make('div','infra-empty',filter?'No matching infrastructure. Try a name, version or address, or clear the filters.':'No infrastructure objects were captured in this snapshot.'));
    };
    const infraKindCounts=new Map();infraNodes.forEach(node=>{if(node.kind!=='group')infraKindCounts.set(node.kind,(infraKindCounts.get(node.kind)||0)+1);});
    for(const [kind,count] of infraKindCounts)infraType.append(new Option(infraTypeLabel({kind})+' ('+count+')',kind));
    for(const [label,kinds] of [['Domains',['domain']],['Clusters',['cluster']],['Hosts',['host']],['Workloads',['vm','template']],['Datastores',['datastore']]]){const card=make('div','infra-total');card.append(make('strong','',kinds.reduce((sum,kind)=>sum+(infraKindCounts.get(kind)||0),0)),document.createTextNode(label));document.getElementById('infra-totals').append(card);}
    infraSearch.addEventListener('input',infraRenderTree);infraType.addEventListener('change',infraRenderTree);document.getElementById('infra-clear').addEventListener('click',()=>{infraSearch.value='';infraType.value='';infraRenderTree();infraSearch.focus();});
    const infraFirst=[...infraNodes.values()].find(node=>node.kind==='domain')||infraNodes.get(infraRoots[0]);if(infraFirst)infraSelect(infraFirst);else infraRenderTree();
    window.vcfDmInfrastructure=Object.freeze({objectCount:[...infraKindCounts.values()].reduce((a,b)=>a+b,0),getObjects:()=>[...infraNodes.values()].filter(node=>node.kind!=='group').map(node=>({key:node.key,kind:node.kind,label:node.label,parent:node.parent,source:node.source,recordCount:node.records.length})),getSelected:()=>infraSelected});
